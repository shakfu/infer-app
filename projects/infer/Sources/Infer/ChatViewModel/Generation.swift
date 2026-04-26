import Foundation
import InferAgents
import InferCore

/// Mutable per-user-turn state shared with the composition driver's
/// `@Sendable` runOne closure. A class (rather than `inout` / captured
/// var) so mutation is legal under strict Swift concurrency. Always
/// mutated on `MainActor` via the closure body, which hops back to
/// MainActor before reading/writing — `@unchecked Sendable` documents
/// the expected isolation.
final class SegmentDispatchState: @unchecked Sendable {
    /// Index of the most recently dispatched segment's assistant
    /// message. After dispatch returns, `send()` reads this to address
    /// the LAST segment's row for TTS / KV-compaction.
    var lastAssistantIndex: Int
    /// Number of segments dispatched so far. The runOne closure uses
    /// `segmentCount == 0` to distinguish "first segment, reuse the
    /// existing assistant skeleton" from "follow-on segment, switch
    /// agent and append a new one."
    var segmentCount: Int

    init(lastAssistantIndex: Int, segmentCount: Int) {
        self.lastAssistantIndex = lastAssistantIndex
        self.segmentCount = segmentCount
    }
}

extension ChatViewModel {
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, modelLoaded, !isGenerating else { return }

        let attachedImage = self.pendingImageURL
        messages.append(ChatMessage(role: .user, text: text, imageURL: attachedImage))
        let nameSnapshot = activeAgentId == DefaultAgent.id ? nil : activeAgentName()
        let labelSnapshot: String? = nameSnapshot.map { name in
            availableAgents.first { $0.id == activeAgentId }?.displayLabel
                ?? AgentListing.makeDisplayLabel(from: name, fallbackId: activeAgentId)
        }
        messages.append(ChatMessage(
            role: .assistant,
            text: "",
            agentId: activeAgentId,
            agentName: nameSnapshot,
            agentLabel: labelSnapshot
        ))
        let assistantIndex = messages.count - 1
        input = ""
        pendingImageURL = nil
        isGenerating = true
        generationTokenCount = 0
        netTokenCount = 0
        generationStart = Date()
        generationEnd = nil

        let backend = self.backend
        // Active agent's decoding params drive the runner-side caps for
        // this turn. `activeDecodingParams` is kept in sync by
        // `switchAgent` (non-Default) and `applySettings` (Default).
        let maxTokens = self.activeDecodingParams.maxTokens
        // Reasoning models (Qwen-3, DeepSeek-R1, etc.) emit
        // `<think>…</think>` content that counts against the runner's
        // decode cap but is stripped from the rendered reply. Treat
        // the user's `maxTokens` as a cap on *net* output (the reply
        // the user actually sees): give the runner
        // `maxTokens + thinkingBudget` of headroom, and stop the
        // stream ourselves once net output hits the user's setting.
        // For non-reasoning models no thinking fires and the two
        // caps are effectively simultaneous.
        let runnerMaxTokens = maxTokens + self.settings.thinkingBudget

        // Record the turn in the vault (best-effort; never blocks generation).
        // Under a non-Default agent the raw system prompt is owned by the
        // agent definition, not by `InferSettings`; persist the agent-id
        // tag so vault rows remain interpretable after schema expands.
        let systemPrompt = activeAgentId == DefaultAgent.id
            ? self.settings.systemPrompt
            : "(agent: \(activeAgentName()))"
        let modelIdForVault = self.vaultModelId()
        let backendName = backend.rawValue
        let workspaceId = self.activeWorkspaceId
        Task { [weak self] in
            guard let self else { return }
            do {
                let cid: Int64
                if let existing = self.currentConversationId {
                    cid = existing
                } else {
                    cid = try await self.vault.startConversation(
                        backend: backendName,
                        modelId: modelIdForVault,
                        systemPrompt: systemPrompt,
                        workspaceId: workspaceId
                    )
                    await MainActor.run { self.currentConversationId = cid }
                }
                try await self.vault.appendMessage(
                    conversationId: cid, role: "user", content: text
                )
                await MainActor.run { self.refreshVaultRecents() }
            } catch {
                // Vault errors are non-fatal. Routed through LogCenter
                // (visible in the Console tab) and mirrored to stderr;
                // we never surface them in the chat UI.
                self.logs.logFromBackground(
                    .error,
                    source: "vault",
                    message: "write failed (user turn)",
                    payload: String(describing: error)
                )
            }
        }

        generationTask = Task {
            // Retrieval-augmented generation: if the active workspace
            // has an indexed corpus, embed the user query, fetch
            // top-K chunks, and build a context-prefixed prompt.
            // Failures downgrade cleanly to a plain reply (no error
            // surfaced to the user); the vault still stores the
            // *original* user text, not the augmented prompt, so
            // history stays clean.
            let augmentation = await self.runRAGIfAvailable(userText: text)
            if augmentation.didAugment,
               assistantIndex < self.messages.count {
                self.messages[assistantIndex].retrievedChunks = augmentation.chunks
            }
            let promptText = augmentation.didAugment
                ? augmentation.augmentedText
                : text

            // Build the composition plan for the active agent. `.single`
            // for every persona / non-composition agent (most cases);
            // `.chain` / `.fallback` for agents that declared composition
            // fields in their JSON. Plan resolution falls back to
            // `.single(activeAgentId)` if the registry can't find the
            // agent (Default), which exercises the same dispatch path.
            let plan: CompositionPlan
            if let active = await self.agentController.registry.agent(id: self.activeAgentId) {
                plan = CompositionPlan.make(for: active)
            } else {
                plan = .single(self.activeAgentId)
            }

            // Phase B: the runOne closure handles per-segment lifecycle
            // — agent switching mid-turn, fresh assistant message
            // creation, per-segment vault writes. State threaded through
            // a class wrapper because the closure is `@Sendable` and
            // SwiftConcurrency rejects captured-var mutation.
            let dispatchState = SegmentDispatchState(
                lastAssistantIndex: assistantIndex,
                segmentCount: 0
            )
            let driver = CompositionController()
            let result = await driver.dispatch(
                plan: plan,
                userText: promptText,
                budget: self.settings.maxAgentSteps,
                runOne: { @Sendable [weak self] segmentAgentId, segmentText in
                    guard let self else {
                        return .failed(message: "vm gone", trace: StepTrace())
                    }
                    return await self.runOneSegment(
                        agentId: segmentAgentId,
                        userText: segmentText,
                        firstSegmentAssistantIndex: assistantIndex,
                        state: dispatchState,
                        runnerMaxTokens: runnerMaxTokens,
                        netCap: maxTokens,
                        backend: backend,
                        attachedImage: attachedImage
                    )
                }
            )

            // Post-dispatch lifecycle. Per `agent_implementation_plan.md`
            // M5a-runtime decision 4: TTS / KV-compaction fire once per
            // *user* turn — not per segment — against the LAST segment's
            // assistant message. Per-segment vault writes happen inside
            // `runOneSegment`. The dispatch outcome carries the final
            // text; we look up the last assistant index from the state.
            let finalIndex = dispatchState.lastAssistantIndex
            switch result.outcome {
            case .completed, .handoff:
                if self.generationEnd == nil { self.generationEnd = Date() }
                if finalIndex < self.messages.count,
                   self.messages[finalIndex].thinkingText?.isEmpty == false {
                    // KV cache holds raw decoded tokens (incl. <think>
                    // blocks); visible reply doesn't. Without compaction
                    // the hidden reasoning carries forward and burns
                    // the context window 2-4x faster than the visible
                    // text suggests. One prefill cost at turn end.
                    self.compactKVForVisibleHistory()
                }
                if self.ttsEnabled, finalIndex < self.messages.count {
                    self.speakAssistantReply(self.messages[finalIndex].text)
                }
            case .abandoned:
                // Cancellation / intentional no-answer. Trace already
                // carries the terminator; nothing to speak, no popup.
                break
            case .failed(let message, _):
                // Real error (not cancellation — those come back as
                // .abandoned). Surface in the UI.
                self.errorMessage = "Generation error: \(message)"
            }
            self.refreshTokenUsage()
            if self.generationEnd == nil { self.generationEnd = Date() }
            self.isGenerating = false
        }
    }

    /// Phase B: per-segment dispatch. Called by the composition driver
    /// once per chain / fallback hop. Handles three concerns the
    /// `runOneAgentTurn` primitive doesn't touch:
    /// 1. **Agent switching** for follow-on segments — invokes
    ///    `AgentController.activateForSegment` (which resets the
    ///    runner's KV cache and pushes the new system prompt + sampling)
    ///    and applies the runner-state effects via `apply(_:)`.
    /// 2. **Fresh assistant message** for follow-on segments — the
    ///    first segment uses the message `send()` already created;
    ///    each subsequent segment gets its own `ChatMessage` so the
    ///    transcript shows each agent's reply distinctly.
    /// 3. **Per-segment vault write** — completed segments persist
    ///    individually so reload preserves attribution.
    /// `attachedImage` is only ever passed to the first segment because
    /// follow-on segments take their predecessor's *text* as input.
    @MainActor
    func runOneSegment(
        agentId: AgentID,
        userText: String,
        firstSegmentAssistantIndex: Int,
        state: SegmentDispatchState,
        runnerMaxTokens: Int,
        netCap: Int,
        backend: Backend,
        attachedImage: URL?
    ) async -> AgentOutcome {
        let isFirstSegment = state.segmentCount == 0
        let segmentIndex: Int
        if isFirstSegment {
            segmentIndex = firstSegmentAssistantIndex
            // Composition wrappers (chain / branch / refine) carry the
            // wrapper's AgentID into the assistant skeleton `send()`
            // pre-created, but segment 0 actually runs a different
            // agent — the chain's first member, the branch's then/else
            // dispatch, the refine's producer. Re-attribute the row so
            // its `agentId` / `agentName` / `agentLabel` reflect the
            // agent whose voice is filling the body. Orchestrator's
            // segment 0 is the router (same id as the wrapper); the
            // condition below is false there, so no re-attribution
            // and no churn.
            if segmentIndex < self.messages.count,
               self.messages[segmentIndex].agentId != agentId {
                let listing = self.availableAgents.first { $0.id == agentId }
                let nameSnapshot = agentId == DefaultAgent.id ? nil : (listing?.name ?? agentId)
                let labelSnapshot: String? = nameSnapshot.map { name in
                    listing?.displayLabel
                        ?? AgentListing.makeDisplayLabel(from: name, fallbackId: agentId)
                }
                self.messages[segmentIndex].agentId = agentId
                self.messages[segmentIndex].agentName = nameSnapshot
                self.messages[segmentIndex].agentLabel = labelSnapshot
            }
        } else {
            // Switch runner state to the new segment's agent. Returns
            // runner-state effects only (no divider, no vault
            // invalidate); apply pushes the new system prompt + sampling
            // into both runners. KV cache is wiped inside the runner
            // by `setSystemPrompt`'s call to `resetConversation`.
            let effects = await self.agentController.activateForSegment(
                agentId: agentId,
                currentBackend: self.currentBackendPreference,
                settings: self.settings
            )
            self.apply(effects)

            // Append a fresh assistant skeleton with the new segment's
            // agent attribution. The role label and per-message metadata
            // are snapshotted now so renaming/deleting the agent later
            // doesn't corrupt scrollback.
            let nameSnapshot = agentId == DefaultAgent.id ? nil : self.agentController.activeAgentName()
            let labelSnapshot: String? = nameSnapshot.map { name in
                self.availableAgents.first { $0.id == agentId }?.displayLabel
                    ?? AgentListing.makeDisplayLabel(from: name, fallbackId: agentId)
            }
            self.messages.append(ChatMessage(
                role: .assistant,
                text: "",
                agentId: agentId,
                agentName: nameSnapshot,
                agentLabel: labelSnapshot
            ))
            segmentIndex = self.messages.count - 1
        }
        state.lastAssistantIndex = segmentIndex
        state.segmentCount += 1

        // customLoop short-circuit. A non-LLM agent
        // (`DeterministicPipelineAgent`, an external-service adapter,
        // any conformance overriding `customLoop`) supplies its full
        // `StepTrace` directly — the chat-VM's LLM decode + tool loop
        // path is bypassed. Falls through to the standard path when
        // the agent returns nil (the common case).
        if let customOutcome = await self.runCustomLoopIfAvailable(
            agentId: agentId,
            userText: userText,
            assistantIndex: segmentIndex
        ) {
            return customOutcome
        }

        let outcome = await self.runOneAgentTurn(
            userText: userText,
            assistantIndex: segmentIndex,
            runnerMaxTokens: runnerMaxTokens,
            netCap: netCap,
            backend: backend,
            // Image only attaches to the first segment — chain segments
            // beyond the first take their predecessor's text as input,
            // not the user's original attachment.
            attachedImage: isFirstSegment ? attachedImage : nil
        )

        // Per-segment vault write: each completed segment persists as
        // its own assistant row. Skip on .abandoned / .failed so
        // partial-output rows don't accumulate in history.
        if case .completed = outcome,
           segmentIndex < self.messages.count,
           let cid = self.currentConversationId {
            let segmentText = self.messages[segmentIndex].text
            let stats = self.generationStats
            Task { [vault = self.vault, logs = self.logs] in
                do {
                    try await vault.appendMessage(
                        conversationId: cid,
                        role: "assistant",
                        content: segmentText,
                        tokens: stats?.tokens,
                        tokPerSec: stats?.tps
                    )
                } catch {
                    logs.logFromBackground(
                        .error,
                        source: "vault",
                        message: "write failed (assistant segment)",
                        payload: String(describing: error)
                    )
                }
            }
        }

        return outcome
    }

    /// Single-agent turn: stream the first decode against the active
    /// runner, run the tool loop if the active agent exposes tools,
    /// and translate the message's final state into an `AgentOutcome`.
    /// All decode errors and cancellations are caught here and converted
    /// to outcomes — the function does not throw — so
    /// `CompositionController` can drive multi-segment dispatches
    /// without per-segment try/catch.
    ///
    /// Phase A wires this for `.single` plans only; Phase B will
    /// handle agent-switching + per-segment assistant-message creation
    /// for chain/fallback dispatches.
    @MainActor
    func runOneAgentTurn(
        userText: String,
        assistantIndex: Int,
        runnerMaxTokens: Int,
        netCap: Int,
        backend: Backend,
        attachedImage: URL?
    ) async -> AgentOutcome {
        let toolSpecs = self.agentController.activeToolSpecs
        let engageToolLoop = backend == .llama && !toolSpecs.isEmpty

        do {
            let stream: AsyncThrowingStream<String, Error>
            switch backend {
            case .llama:
                // llama backend has no multimodal path here; the send
                // button is disabled when an image is attached, so this
                // branch will not carry one in practice.
                stream = await self.llama.sendUserMessage(userText, maxTokens: runnerMaxTokens)
            case .mlx:
                let imgs: [URL] = attachedImage.map { [$0] } ?? []
                stream = await self.mlx.sendUserMessage(
                    userText, imageURLs: imgs, maxTokens: runnerMaxTokens
                )
            }
            var firstDecodeText = ""
            // Strip <think>…</think> reasoning blocks from the
            // visible body and capture them into the message's
            // `thinkingText` for the collapsible disclosure.
            // The filter is stateful across pieces because tags
            // can split mid-chunk.
            var thinkFilter = ThinkBlockStreamFilter()
            for try await piece in stream {
                let display = thinkFilter.feed(piece)
                if assistantIndex < self.messages.count {
                    if !display.isEmpty {
                        self.messages[assistantIndex].text += display
                    }
                    self.messages[assistantIndex].isThinking = thinkFilter.inThink
                    if !thinkFilter.thinking.isEmpty {
                        self.messages[assistantIndex].thinkingText = thinkFilter.thinking
                    }
                }
                firstDecodeText += piece
                self.generationTokenCount += 1
                if !display.isEmpty {
                    self.netTokenCount += 1
                }
                if self.generationTokenCount % 16 == 0 {
                    self.refreshTokenUsage()
                }
                // Net-token cap. Once the rendered reply has reached
                // the user's `maxTokens` AND we're not still inside a
                // <think> block, stop the runner. The out-of-think
                // check matters for reasoning models that emit
                // closing `</think>` right before the answer — the
                // filter must see it so the first net token counts.
                if self.netTokenCount >= netCap, !thinkFilter.inThink {
                    await self.requestStopCurrentRunner()
                    break
                }
            }
            // Flush any pending tail (e.g. unterminated <think> or
            // partial-tag holdback that turned out literal).
            let tail = thinkFilter.flush()
            if assistantIndex < self.messages.count {
                if !tail.isEmpty {
                    self.messages[assistantIndex].text += tail
                }
                self.messages[assistantIndex].isThinking = false
                if !thinkFilter.thinking.isEmpty {
                    self.messages[assistantIndex].thinkingText = thinkFilter.thinking
                }
            }

            if engageToolLoop {
                try await self.maybeRunToolLoop(
                    firstDecodeText: firstDecodeText,
                    assistantIndex: assistantIndex,
                    maxTokens: runnerMaxTokens,
                    netCap: netCap
                )
            }

            self.generationEnd = Date()

            // Translate the final message state into an outcome. The
            // tool loop already stamped `.finalAnswer(...)` as the
            // trace terminator on success; for the no-tool path we
            // synthesise a single-step trace from the visible body.
            let finalText = assistantIndex < self.messages.count
                ? self.messages[assistantIndex].text
                : ""
            let trace = self.messages[assistantIndex].steps
                ?? StepTrace.finalAnswer(finalText)

            // Handoff envelope: if the agent embedded `<<HANDOFF>>`
            // in its visible body, strip the envelope and return a
            // `.handoff` outcome the composition driver will follow.
            // Single-agent dispatch ignores the envelope; chain/
            // fallback consume it. (Phase A: not exercised by any
            // shipping agent.)
            let parsed = HandoffEnvelope.parse(finalText)
            if let handoff = parsed.handoff {
                if assistantIndex < self.messages.count {
                    self.messages[assistantIndex].text = parsed.visibleText
                }
                return .handoff(target: handoff.target, payload: handoff.payload, trace: trace)
            }

            return .completed(text: finalText, trace: trace)
        } catch is CancellationError {
            self.finalizeIncompleteTrace(at: assistantIndex, with: .cancelled)
            return .abandoned(
                reason: "cancelled",
                trace: self.messages[assistantIndex].steps ?? StepTrace(steps: [.cancelled])
            )
        } catch LlamaError.cancelled {
            self.finalizeIncompleteTrace(at: assistantIndex, with: .cancelled)
            return .abandoned(
                reason: "cancelled",
                trace: self.messages[assistantIndex].steps ?? StepTrace(steps: [.cancelled])
            )
        } catch MLXRunnerError.cancelled {
            self.finalizeIncompleteTrace(at: assistantIndex, with: .cancelled)
            return .abandoned(
                reason: "cancelled",
                trace: self.messages[assistantIndex].steps ?? StepTrace(steps: [.cancelled])
            )
        } catch {
            let message = String(describing: error)
            self.finalizeIncompleteTrace(at: assistantIndex, with: .error(message))
            return .failed(
                message: message,
                trace: self.messages[assistantIndex].steps
                    ?? StepTrace(steps: [.error(message)])
            )
        }
    }

    /// Signal whichever backend is currently running to stop at the
    /// next cancellation check. Used by both the user-initiated Stop
    /// button and the internal net-token-cap breaker (when reasoning
    /// models finish their reply inside a larger decode budget).
    /// Unlike `stop()`, doesn't cancel the VM-level `generationTask`
    /// — the stream loop is breaking out on its own and needs to
    /// finish committing state (vault write, TTS, KV compaction).
    func requestStopCurrentRunner() async {
        switch self.backend {
        case .llama: await self.llama.requestStop()
        case .mlx: await self.mlx.requestStop()
        }
    }

    func stop() {
        let b = self.backend
        Task {
            switch b {
            case .llama: await self.llama.requestStop()
            case .mlx: await self.mlx.requestStop()
            }
        }
        generationTask?.cancel()
        generationTask = nil
        speechSynthesizer.stop()
    }

    /// Regenerate the most recent assistant response. Pops the last
    /// user+assistant pair from the transcript, rewinds the backend so its
    /// KV cache matches, then re-sends the original user turn (with any
    /// attached image) via `send()`.
    ///
    /// No-op when a generation is in flight, when the last two messages
    /// aren't a user→assistant pair, or when no model is loaded.
    func regenerateLast() {
        guard unspoolLastTurn() else { return }
        let b = self.backend
        Task {
            switch b {
            case .llama: await self.llama.rewindLastTurn()
            case .mlx: await self.mlx.rewindLastTurn()
            }
            await MainActor.run { self.send() }
        }
    }

    /// Pop the most recent user turn (and its assistant reply) back into the
    /// composer for editing. Next press of Send re-runs the turn. Same rewind
    /// mechanics as `regenerateLast` — the backend's pre-turn state is
    /// restored — but control returns to the user before sending.
    func editLastUserMessage() {
        guard unspoolLastTurn() else { return }
        let b = self.backend
        Task {
            switch b {
            case .llama: await self.llama.rewindLastTurn()
            case .mlx: await self.mlx.rewindLastTurn()
            }
        }
    }

    /// After the first decode completes, look for a Llama 3.1 tool call
    /// in the assistant text. If found: strip the raw tool tokens from
    /// the visible body, stamp the trace with the request (so the UI
    /// shows a spinner while the tool runs), invoke the tool, stamp the
    /// result, then run a second decode for the final answer.
    ///
    /// The trace is stamped in three stages so `StepTraceDisclosure` can
    /// render intermediate states:
    ///   1. `.assistantText(prefix)` + `.toolCall` — spinner: "running X…"
    ///   2. `.toolResult` appended — spinner: "awaiting final answer…"
    ///   3. `.finalAnswer` appended — terminator; disclosure settles.
    ///
    /// If the turn is cancelled or errors out before reaching stage 3,
    /// the caller (`send`) finalises the trace with the appropriate
    /// terminator so historical rows never show a perpetual spinner.
    ///
    /// One step per turn (`maxSteps = 1`). Multi-step is deferred to a
    /// later PR — this fires at most once.
    @MainActor
    func maybeRunToolLoop(
        firstDecodeText: String,
        assistantIndex: Int,
        maxTokens: Int,
        netCap: Int
    ) async throws {
        let parser = ToolCallParser(
            family: ToolCallParser.Family(agentController.activeToolFamily)
        )
        guard let match = parser.findFirstCall(in: firstDecodeText) else { return }
        guard assistantIndex < self.messages.count else { return }

        // All trace mutations route through `emitToolLoopEvent` so the
        // bytewise shape of `messages[i].steps` is dictated by
        // `AgentEvent.applyToTrace`. Visible body / `isThinking` /
        // `thinkingText` mutations remain inline because they depend on
        // the streaming think-block filter, not on the trace.

        // Stage 1: strip the tool-call tag from the visible body and
        // stamp the in-flight trace. Disclosure UI shows "running <tool>…".
        //
        // `match.prefix` is the *raw* prefix from the unfiltered stream
        // — including any `<think>...</think>` blocks the model emitted
        // before the tool call. Both the visible body and the trace's
        // `.assistantText` step want the *filtered* prefix instead, so
        // the slice we compute from the already-filtered
        // `messages[i].text` is the source of truth.
        let visiblePrefix: String
        if assistantIndex < self.messages.count,
           let tagRange = self.messages[assistantIndex].text.range(of: parser.openTag) {
            visiblePrefix = String(
                self.messages[assistantIndex].text[..<tagRange.lowerBound]
            )
            self.messages[assistantIndex].text = visiblePrefix
        } else {
            visiblePrefix = assistantIndex < self.messages.count
                ? self.messages[assistantIndex].text
                : ""
        }
        self.emitToolLoopEvent(
            .toolRequested(prefix: visiblePrefix, call: match.call),
            at: assistantIndex
        )
        self.emitToolLoopEvent(
            .toolRunning(name: match.call.name),
            at: assistantIndex
        )

        // Stage 2: invoke the tool. Registry errors surface into
        // `ToolResult` with an `error` field; the model sees them as
        // ipython content and can recover.
        let toolResult: ToolResult
        do {
            toolResult = try await self.toolRegistry.invoke(
                name: match.call.name,
                arguments: match.call.arguments
            )
        } catch {
            toolResult = ToolResult(
                output: "",
                error: "tool invocation failed: \(error)"
            )
        }
        if assistantIndex < self.messages.count {
            self.emitToolLoopEvent(.toolResulted(toolResult), at: assistantIndex)
        }

        // Stage 3: feed the tool output back as an ipython-role message
        // and decode the final answer. Prefer `error` when set so the
        // model sees what failed.
        let feedback = toolResult.error ?? toolResult.output
        let secondStream = await self.llama.appendToolResultAndContinue(
            toolResult: feedback,
            family: agentController.activeToolFamily,
            maxTokens: maxTokens
        )
        var finalAnswer = ""
        // Same think-block filter as the first decode — reasoning
        // models can emit <think> in either decode pass.
        var thinkFilter2 = ThinkBlockStreamFilter()
        for try await piece in secondStream {
            let display = thinkFilter2.feed(piece)
            if assistantIndex < self.messages.count {
                if !display.isEmpty {
                    self.messages[assistantIndex].text += display
                }
                self.messages[assistantIndex].isThinking = thinkFilter2.inThink
                if !thinkFilter2.thinking.isEmpty {
                    self.messages[assistantIndex].thinkingText = thinkFilter2.thinking
                }
            }
            finalAnswer += piece
            // Notify observers of the streamed second-decode chunk.
            // No trace effect — `AgentEvent.applyToTrace` ignores
            // `.finalChunk`. Carries the post-think-filter text so a UI
            // observer sees what the user is about to read; the raw
            // piece is preserved in the `finalAnswer` accumulator that
            // lands as `.finalAnswer(...)` below.
            if !display.isEmpty {
                self.emitToolLoopEvent(.finalChunk(display), at: assistantIndex)
            }
            self.generationTokenCount += 1
            if !display.isEmpty {
                self.netTokenCount += 1
            }
            // Match the periodic refresh in the first-decode loop
            // so the header keeps climbing during the tool-loop's
            // second decode too.
            if self.generationTokenCount % 16 == 0 {
                self.refreshTokenUsage()
            }
            // Net-token cap for the tool loop's second decode.
            // Same rule as the first decode — ignore thinking
            // content, enforce the user's cap on rendered output.
            if self.netTokenCount >= netCap, !thinkFilter2.inThink {
                await self.requestStopCurrentRunner()
                break
            }
        }
        let tail2 = thinkFilter2.flush()
        if assistantIndex < self.messages.count {
            if !tail2.isEmpty {
                self.messages[assistantIndex].text += tail2
            }
            self.messages[assistantIndex].isThinking = false
            if !thinkFilter2.thinking.isEmpty {
                self.messages[assistantIndex].thinkingText = thinkFilter2.thinking
            }
        }
        if assistantIndex < self.messages.count {
            self.emitToolLoopEvent(
                .terminated(.finalAnswer(finalAnswer)),
                at: assistantIndex
            )
        }
    }

    /// Apply an `AgentEvent` to the assistant message at `index`, then
    /// forward it to `AgentController.events` so external observers
    /// (streaming disclosure UI, exporters, tests) see it.
    ///
    /// Trace mutations are delegated to `AgentEvent.applyToTrace` so
    /// there is exactly one definition of "what goes into the trace
    /// when X happens" — covered by `AgentEventTests.bytewiseFinalTrace`.
    /// Visible-body / `isThinking` mutations stay in the loop driver
    /// because they depend on the streaming `ThinkBlockStreamFilter`
    /// state that doesn't fit a per-event interface.
    @MainActor
    func emitToolLoopEvent(_ event: AgentEvent, at index: Int) {
        guard index < messages.count else { return }
        // Lazy-initialise the trace on first event.
        var trace = messages[index].steps ?? StepTrace()
        let before = trace.steps.count
        event.applyToTrace(&trace)
        if trace.steps.count != before {
            messages[index].steps = trace
        }
        agentController.emit(event)
    }

    /// Append a terminator step to an in-flight trace. Called from the
    /// cancel/error paths in `send` so the disclosure UI doesn't render
    /// a perpetual spinner on turns that ended abnormally. Also forwards
    /// the corresponding `.terminated` event to the controller's stream
    /// so subscribers see end-of-turn even on the abnormal paths.
    @MainActor
    func finalizeIncompleteTrace(
        at index: Int,
        with terminator: StepTrace.Step
    ) {
        guard index < messages.count else { return }
        guard let trace = messages[index].steps, trace.terminator == nil else { return }
        emitToolLoopEvent(.terminated(terminator), at: index)
    }

    /// Resolve the active segment's agent and call its `customLoop`
    /// hook. Returns the AgentOutcome and writes the trace + final
    /// text into the segment's `ChatMessage` when the agent has a
    /// custom implementation (deterministic / non-LLM / external-
    /// service agents). Returns nil to signal "no custom loop, host
    /// must run its standard LLM decode path."
    ///
    /// The vault write for completed segments is delegated back to
    /// `runOneSegment`'s post-call block — we return the outcome and
    /// let the existing persistence logic fire there. This keeps the
    /// short-circuit additive: it adds one branch and shares every
    /// other piece of segment-completion plumbing with the LLM path.
    @MainActor
    private func runCustomLoopIfAvailable(
        agentId: AgentID,
        userText: String,
        assistantIndex: Int
    ) async -> AgentOutcome? {
        // Default agent has no JSON-backed registry entry and never
        // overrides customLoop, so the lookup is skipped — the
        // standard LLM path handles every Default-agent turn.
        guard agentId != DefaultAgent.id else { return nil }
        guard let agent = await agentController.registry.agent(id: agentId) else {
            return nil
        }
        let toolRegistry = self.toolRegistry
        let invoker: ToolInvoker = { name, args in
            try await toolRegistry.invoke(name: name, arguments: args)
        }
        let context = AgentContext(
            runner: RunnerHandle(
                backend: currentBackendPreference,
                templateFamily: agentController.activeToolFamily,
                maxContext: 0,
                currentTokenCount: 0
            ),
            tools: agentController.toolCatalog,
            transcript: [],
            stepCount: 0,
            retrieve: agentController.retriever,
            invokeTool: invoker
        )
        let trace: StepTrace?
        do {
            trace = try await agent.customLoop(
                turn: AgentTurn(userText: userText),
                context: context
            )
        } catch {
            logs.log(
                .warning,
                source: "agents",
                message: "customLoop threw for \(agentId)",
                payload: String(describing: error)
            )
            // Fall through to LLM path on a customLoop throw — the
            // host's standard loop is the safe fallback. The error is
            // preserved in the Console for debugging.
            return nil
        }
        guard let trace else { return nil }

        // Materialise the trace into the segment's ChatMessage. Pull
        // the user-visible text from the trace's terminator (when
        // it's a finalAnswer); other terminators surface as outcomes
        // without a body so the composition layer can route them.
        let finalText: String
        switch trace.terminator {
        case .finalAnswer(let text): finalText = text
        case .cancelled, .budgetExceeded, .error, .none: finalText = ""
        default: finalText = ""
        }
        if assistantIndex < messages.count {
            messages[assistantIndex].text = finalText
            messages[assistantIndex].steps = trace
        }
        // Mirror the LLM path's event emission so observers see a
        // single `terminated` event regardless of whether the segment
        // was driven by an LLM decode or a custom loop.
        if let term = trace.terminator {
            agentController.emit(.terminated(term))
        }

        switch trace.terminator {
        case .finalAnswer(let text):
            return .completed(text: text, trace: trace)
        case .cancelled:
            return .abandoned(reason: "cancelled", trace: trace)
        case .budgetExceeded:
            return .failed(message: "step budget exhausted", trace: trace)
        case .error(let message):
            return .failed(message: message, trace: trace)
        case .none, .some:
            return .completed(text: finalText, trace: trace)
        }
    }

    /// Shared precondition + transcript mutation for regenerate and
    /// edit-and-resend. Returns `true` when the last user+assistant pair was
    /// popped and the composer repopulated with the original user text +
    /// image; `false` means the caller should abort (no-op).
    private func unspoolLastTurn() -> Bool {
        guard modelLoaded, !isGenerating else { return false }
        guard messages.count >= 2 else { return false }
        let last = messages.count - 1
        guard messages[last].role == .assistant,
              messages[last - 1].role == .user
        else { return false }

        let userTurn = messages[last - 1]
        messages.removeSubrange((last - 1)...last)
        input = userTurn.text
        pendingImageURL = userTurn.imageURL
        return true
    }
}
