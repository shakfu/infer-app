import Foundation
import InferAgents
import InferCore

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
        generationStart = Date()
        generationEnd = nil

        let backend = self.backend
        // Active agent's decoding params drive the runner-side caps for
        // this turn. `activeDecodingParams` is kept in sync by
        // `switchAgent` (non-Default) and `applySettings` (Default).
        let maxTokens = self.activeDecodingParams.maxTokens

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

        // Tool loop is llama-only and only engages when the active agent
        // exposes at least one tool. MLX gets the existing single-stream
        // path; so does llama-with-Default.
        let toolSpecs = self.agentController.activeToolSpecs
        let engageToolLoop = backend == .llama && !toolSpecs.isEmpty

        generationTask = Task {
            do {
                // Retrieval-augmented generation: if the active
                // workspace has an indexed corpus, embed the user
                // query, fetch top-K chunks, and build a context-
                // prefixed prompt. Failures downgrade cleanly to a
                // plain reply (no error surfaced to the user); the
                // vault still stores the *original* user text, not
                // the augmented prompt, so history stays clean.
                let augmentation = await self.runRAGIfAvailable(userText: text)
                if augmentation.didAugment,
                   assistantIndex < self.messages.count {
                    self.messages[assistantIndex].retrievedChunks = augmentation.chunks
                }
                let promptText = augmentation.didAugment
                    ? augmentation.augmentedText
                    : text

                let stream: AsyncThrowingStream<String, Error>
                switch backend {
                case .llama:
                    // llama backend has no multimodal path here; the send
                    // button is disabled when an image is attached, so this
                    // branch will not carry one in practice.
                    stream = await self.llama.sendUserMessage(promptText, maxTokens: maxTokens)
                case .mlx:
                    let imgs: [URL] = attachedImage.map { [$0] } ?? []
                    stream = await self.mlx.sendUserMessage(
                        promptText, imageURLs: imgs, maxTokens: maxTokens
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
                        // Update thinking state on the message in
                        // real time so the disclosure header shows
                        // live "thinking…" while the model is in a
                        // <think> block.
                        self.messages[assistantIndex].isThinking = thinkFilter.inThink
                        if !thinkFilter.thinking.isEmpty {
                            self.messages[assistantIndex].thinkingText = thinkFilter.thinking
                        }
                    }
                    firstDecodeText += piece
                    self.generationTokenCount += 1
                    // Refresh the header's context-percentage every
                    // 16 tokens so it climbs visibly during streaming
                    // rather than jumping at completion. The llama
                    // path reads `seq_pos_max` (O(1)) so this is
                    // cheap; the MLX path estimates from char count
                    // which is similarly cheap.
                    if self.generationTokenCount % 16 == 0 {
                        self.refreshTokenUsage()
                    }
                }
                // Flush any pending tail (e.g. unterminated <think>
                // or partial-tag holdback that turned out literal).
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
                        maxTokens: maxTokens
                    )
                }

                self.generationEnd = Date()
                // Persist the assistant reply to the vault. Only on success —
                // cancellations and errors are caught below and skip this.
                if assistantIndex < self.messages.count,
                   let cid = self.currentConversationId {
                    let finalText = self.messages[assistantIndex].text
                    let stats = self.generationStats
                    Task { [vault = self.vault] in
                        do {
                            try await vault.appendMessage(
                                conversationId: cid,
                                role: "assistant",
                                content: finalText,
                                tokens: stats?.tokens,
                                tokPerSec: stats?.tps
                            )
                        } catch {
                            self.logs.logFromBackground(
                                .error,
                                source: "vault",
                                message: "write failed (assistant turn)",
                                payload: String(describing: error)
                            )
                        }
                    }
                }
                if self.ttsEnabled, assistantIndex < self.messages.count {
                    let finalText = self.messages[assistantIndex].text
                    self.speakAssistantReply(finalText)
                }
                self.refreshTokenUsage()
            } catch is CancellationError {
                // user-initiated stop
                self.finalizeIncompleteTrace(at: assistantIndex, with: .cancelled)
            } catch LlamaError.cancelled {
                // user-initiated stop
                self.finalizeIncompleteTrace(at: assistantIndex, with: .cancelled)
            } catch MLXRunnerError.cancelled {
                // user-initiated stop
                self.finalizeIncompleteTrace(at: assistantIndex, with: .cancelled)
            } catch {
                self.errorMessage = "Generation error: \(error)"
                self.finalizeIncompleteTrace(
                    at: assistantIndex,
                    with: .error(String(describing: error))
                )
            }
            if self.generationEnd == nil { self.generationEnd = Date() }
            self.isGenerating = false
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
        maxTokens: Int
    ) async throws {
        let parser = ToolCallParser(family: .llama3)
        guard let match = parser.findFirstCall(in: firstDecodeText) else { return }
        guard assistantIndex < self.messages.count else { return }

        // Stage 1: strip raw tool tokens from the visible text and stamp
        // the in-flight trace. The disclosure UI now shows a spinner
        // with "running <tool>…".
        self.messages[assistantIndex].text = match.prefix
        var trace = StepTrace()
        if !match.prefix.isEmpty {
            trace.steps.append(.assistantText(match.prefix))
        }
        trace.steps.append(.toolCall(match.call))
        self.messages[assistantIndex].steps = trace

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
            self.messages[assistantIndex].steps?.steps.append(.toolResult(toolResult))
        }

        // Stage 3: feed the tool output back as an ipython-role message
        // and decode the final answer. Prefer `error` when set so the
        // model sees what failed.
        let feedback = toolResult.error ?? toolResult.output
        let secondStream = await self.llama.appendToolResultAndContinue(
            toolResult: feedback,
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
            self.generationTokenCount += 1
            // Match the periodic refresh in the first-decode loop
            // so the header keeps climbing during the tool-loop's
            // second decode too.
            if self.generationTokenCount % 16 == 0 {
                self.refreshTokenUsage()
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
            self.messages[assistantIndex].steps?.steps.append(.finalAnswer(finalAnswer))
        }
    }

    /// Append a terminator step to an in-flight trace. Called from the
    /// cancel/error paths in `send` so the disclosure UI doesn't render
    /// a perpetual spinner on turns that ended abnormally.
    @MainActor
    func finalizeIncompleteTrace(
        at index: Int,
        with terminator: StepTrace.Step
    ) {
        guard index < messages.count else { return }
        guard var trace = messages[index].steps, trace.terminator == nil else { return }
        trace.steps.append(terminator)
        messages[index].steps = trace
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
