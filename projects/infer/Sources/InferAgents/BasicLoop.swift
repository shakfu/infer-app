import Foundation

/// Runner-agnostic loop driver for `Agent` conformances.
///
/// `BasicLoop` is the alternative to `ChatViewModel/Generation.swift` —
/// it drives the same agent hooks (`systemPrompt`, `toolsAvailable`,
/// `transformToolResult`, `shouldContinue`) against any `AgentRunner`,
/// without dependencies on the SwiftUI VM, the vault, KV compaction,
/// or speech. Use it from CLI, batch evaluations, tests, or any
/// host that doesn't need the chat-VM bundle.
///
/// Supported turn shapes (in order of how the loop drives them):
///
/// 1. *Custom-loop agents.* If `agent.customLoop` returns a non-nil
///    `StepTrace`, that trace IS the turn. No `AgentRunner` is
///    invoked. Used by deterministic / tool-only / external-service
///    agents.
/// 2. *Single-decode agents.* Decode produces text with no tool
///    call → emit `finalAnswer`. The common case.
/// 3. *One-tool-call cycle.* Decode produces a tool call; loop
///    invokes the tool, transforms the result, decodes again, emits
///    `finalAnswer`. The standard agentic shape.
/// 4. *Multi-tool cycles.* The loop iterates while
///    `agent.shouldContinue(...) == .continue`, up to `budget` steps.
///    Each iteration is one decode + optional tool call.
///
/// Out of scope (deferred to the chat-VM loop or future work):
/// mid-stream interruption, KV-cache reuse, think-block stripping
/// at the loop level (handled per-runner conformance), parallel tool
/// calls. The protocol stays small enough that adding these later
/// doesn't require refactoring callers.
public enum BasicLoop {

    public struct Config: Sendable, Equatable {
        /// Maximum number of decode-or-customLoop steps per turn. Each
        /// LLM decode counts as 1; a `customLoop` call counts as 1
        /// regardless of internal complexity. Default 6 covers the
        /// common shapes (single decode, one-tool cycle = 2 decodes,
        /// two-tool cycle = 3 decodes) with headroom.
        public var stepBudget: Int
        /// Tool-call template family the runner emits. Defaults to
        /// `.llama3` to match historical behaviour. Callers driving
        /// Qwen / Hermes models should pass the matching family so
        /// the parser tags align with what the model produces.
        public var toolCallFamily: ToolCallParser.Family

        public init(stepBudget: Int = 6, toolCallFamily: ToolCallParser.Family = .llama3) {
            self.stepBudget = stepBudget
            self.toolCallFamily = toolCallFamily
        }
    }

    /// Drive `agent` to a terminal `StepTrace`.
    ///
    /// The loop never throws on an agent's own logic failures —
    /// `shouldContinue` errors degrade to "stop", tool errors are
    /// surfaced as `ToolResult(error:)` and fed back to the model,
    /// and budget exhaustion produces a `.budgetExceeded` terminator.
    /// Throws only on infrastructure failures (the runner stream
    /// errors mid-decode, `Task.cancel` propagates through, the host's
    /// tool invoker is missing when an agent demands one).
    public static func run(
        agent: any Agent,
        turn: AgentTurn,
        context: AgentContext,
        runner: any AgentRunner,
        config: Config = Config(),
        events: ((AgentEvent) -> Void)? = nil
    ) async throws -> StepTrace {

        // 1. Custom-loop short-circuit. Deterministic / tool-only /
        // external-service / planner agents produce their trace
        // directly here. Inject a decoder closure (item 10) so an
        // LLM-driven custom loop (`PlannerAgent`) can reach the
        // runner without needing a reference to it. The host-passed
        // context is snapshotted with the new hook attached; existing
        // fields (`tools`, `transcript`, `invokeTool`, `retrieve`)
        // pass through unchanged.
        let runnerCopy: any AgentRunner = runner
        let decoder: AgentDecoder = { messages, params in
            let stream = runnerCopy.decode(messages: messages, params: params)
            var text = ""
            for try await chunk in stream {
                text += chunk
            }
            return text
        }
        let customCtx = AgentContext(
            runner: context.runner,
            tools: context.tools,
            transcript: context.transcript,
            stepCount: context.stepCount,
            retrieve: context.retrieve,
            invokeTool: context.invokeTool,
            decode: context.decode ?? decoder
        )
        if let custom = try await agent.customLoop(turn: turn, context: customCtx) {
            // Even though the loop didn't decode, replay the trace's
            // terminal step through the event hook so observers see a
            // single `terminated` event regardless of agent shape.
            if let terminator = custom.terminator {
                events?(.terminated(terminator))
            }
            return custom
        }

        // 2. Standard decoded loop. Build the working transcript by
        // appending the user turn to the snapshot the host passed in;
        // each tool result extends it for the subsequent decode.
        var workingTranscript = context.transcript
        // System prompt always comes first. The host built one already
        // in `AgentController.composeSystemPrompt`, but the snapshot
        // in `context.transcript` may already include it; re-derive
        // here so a context built without a system row also works.
        let basePrompt = try await agent.systemPrompt(for: context)
        let toolSpecs = try await agent.toolsAvailable(for: context)
        let composedPrompt = AgentController.composeSystemPrompt(
            base: basePrompt,
            tools: toolSpecs,
            family: context.runner.templateFamily ?? .llama3
        )
        if !composedPrompt.isEmpty,
           !workingTranscript.contains(where: { $0.role == .system }) {
            workingTranscript.insert(
                TranscriptMessage(role: .system, content: composedPrompt),
                at: 0
            )
        }
        workingTranscript.append(
            TranscriptMessage(role: .user, content: turn.userText)
        )

        let parser = ToolCallParser(family: config.toolCallFamily)
        let params = agent.decodingParams(for: context)
        var trace = StepTrace()
        var stepsRemaining = config.stepBudget

        while stepsRemaining > 0 {
            stepsRemaining -= 1

            // Decode one assistant turn against the working transcript.
            var emitted = ""
            let stream = runner.decode(messages: workingTranscript, params: params)
            do {
                for try await chunk in stream {
                    emitted += chunk
                    events?(.assistantChunk(chunk))
                    try Task.checkCancellation()
                }
            } catch is CancellationError {
                let step = StepTrace.Step.cancelled
                trace.steps.append(step)
                events?(.terminated(step))
                return trace
            }

            // Tool-call detection. Single call per turn is the standard
            // shape; the loop's iteration handles multi-call cycles by
            // re-entering with the result appended.
            if let match = parser.findFirstCall(in: emitted) {
                let trimmedPrefix = match.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPrefix.isEmpty {
                    trace.steps.append(.assistantText(trimmedPrefix))
                }
                trace.steps.append(.toolCall(match.call))
                events?(.toolRequested(prefix: trimmedPrefix, call: match.call))

                // Invoke. A missing invoker on a tool-calling agent is
                // a host configuration error — fail loud.
                guard let invoke = context.invokeTool else {
                    throw AgentError.toolInvokerMissing
                }
                events?(.toolRunning(name: match.call.name))
                let raw: ToolResult
                do {
                    raw = try await invoke(match.call.name, match.call.arguments)
                } catch {
                    raw = ToolResult(
                        output: "",
                        error: "tool dispatch failed: \(error.localizedDescription)"
                    )
                }
                let transformed = try await agent.transformToolResult(
                    raw, call: match.call, context: context
                )
                trace.steps.append(.toolResult(transformed))
                events?(.toolResulted(transformed))

                // Feed the assistant + tool messages back into the
                // transcript and let `shouldContinue` decide whether
                // another decode round runs.
                workingTranscript.append(
                    TranscriptMessage(role: .assistant, content: emitted)
                )
                workingTranscript.append(
                    TranscriptMessage(role: .tool, content: transformed.output)
                )
                let decision = await agent.shouldContinue(
                    after: .toolResult(transformed),
                    context: context
                )
                if case .stop = decision {
                    let step = StepTrace.Step.finalAnswer("")
                    trace.steps.append(step)
                    events?(.terminated(step))
                    return trace
                }
                continue
            }

            // No tool call detected → this is the final answer. Replay
            // the accumulated text as a single `finalAnswer` step. The
            // event hook already saw it as a sequence of
            // `assistantChunk`s, so observers don't double-up.
            let answer = emitted.trimmingCharacters(in: .whitespacesAndNewlines)
            let step = StepTrace.Step.finalAnswer(answer)
            trace.steps.append(step)
            events?(.terminated(step))
            return trace
        }

        // Budget exhausted before a terminator fired.
        let step = StepTrace.Step.budgetExceeded
        trace.steps.append(step)
        events?(.terminated(step))
        return trace
    }

    /// Convenience: drive an agent to completion and return an
    /// `AgentOutcome` instead of a raw `StepTrace`. Suitable as the
    /// `runOne` closure for `CompositionController.dispatch` when the
    /// host wants `BasicLoop` to handle every segment.
    public static func runOutcome(
        agent: any Agent,
        turn: AgentTurn,
        context: AgentContext,
        runner: any AgentRunner,
        config: Config = Config(),
        events: ((AgentEvent) -> Void)? = nil
    ) async -> AgentOutcome {
        do {
            let trace = try await run(
                agent: agent,
                turn: turn,
                context: context,
                runner: runner,
                config: config,
                events: events
            )
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
                // `terminator` returns nil for a trace whose last step
                // isn't a terminal case, or one of the non-terminal
                // cases above. Treat as completion of whatever text
                // accumulated; the agent layer's other primitives
                // already tolerate empty completions.
                let text: String
                if case .finalAnswer(let t) = trace.steps.last { text = t } else { text = "" }
                return .completed(text: text, trace: trace)
            }
        } catch {
            var trace = StepTrace()
            trace.steps.append(.error(String(describing: error)))
            return .failed(message: String(describing: error), trace: trace)
        }
    }
}
