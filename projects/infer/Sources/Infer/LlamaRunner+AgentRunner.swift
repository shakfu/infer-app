import Foundation
import InferAgents

/// Stateless `AgentRunner` adapter over the stateful `LlamaRunner`
/// actor. Provided so `BasicLoop` (which lives in `InferAgents` and
/// expects a stateless `decode(messages:params:)` shape) can drive a
/// real llama.cpp model — useful for CLI / batch / integration tests
/// that don't go through `ChatViewModel`.
///
/// **KV cache caveat.** `LlamaRunner` was designed around the chat-VM's
/// per-turn flow, where the system prompt is set once and successive
/// `sendUserMessage` calls share the prefix-decoded KV cache across the
/// conversation. This adapter re-establishes the system prompt and
/// history on every `decode` call (`setSystemPrompt` clears the KV;
/// `setHistory` rebuilds it). For a multi-turn conversation that means
/// roughly N× the prefill work over the conversation versus the
/// chat-VM path. Acceptable for short / one-shot / batch use cases —
/// not for long interactive sessions through `BasicLoop`. When a real
/// caller appears that needs both, the right move is a stateful
/// `AgentRunner` variant or a session intermediate, not a refactor of
/// this adapter.
///
/// **Tool-cycle handling.** When `BasicLoop` re-enters `decode` after a
/// tool call, the last `TranscriptMessage` carries `role == .tool`.
/// The adapter detects this shape and routes through
/// `appendToolResultAndContinue`, which writes the right family-aware
/// role (`ipython` for Llama 3 / OpenAI templates, `tool` for Qwen /
/// Hermes) into the chat template. The naive "treat tool as history"
/// path that other runners might use would render the wrong role tag
/// for Llama 3 templates and break the follow-up answer.
extension LlamaRunner: AgentRunner {
    public nonisolated func decode(
        messages: [TranscriptMessage],
        params: DecodingParams
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                await Self.performAgentDecode(
                    runner: self,
                    messages: messages,
                    params: params,
                    continuation: continuation
                )
            }
            // If the consumer cancels the stream, propagate to the
            // underlying decode loop. `LlamaRunner.requestStop` is the
            // documented cancellation entry; the actor's cancel flag
            // unwinds the detached decode task on the next token.
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.requestStop() }
            }
        }
    }

    private static func performAgentDecode(
        runner: LlamaRunner,
        messages: [TranscriptMessage],
        params: DecodingParams,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        do {
            await runner.updateSampling(
                temperature: Float(params.temperature),
                topP: Float(params.topP),
                topK: 40,
                seed: nil
            )

            // Tool-cycle: BasicLoop appends `(.assistant, raw)` then
            // `(.tool, result)` and re-enters decode. Detect and route
            // through the family-aware tool-result path.
            if let last = messages.last, last.role == .tool {
                let prior = Array(messages.dropLast())
                let split = Self.split(messages: prior)
                await runner.setSystemPrompt(split.system)
                try await runner.setHistory(split.history)
                let family = await runner.detectedTemplateFamily() ?? .llama3
                let stream = await runner.appendToolResultAndContinue(
                    toolResult: last.content,
                    family: family,
                    maxTokens: params.maxTokens
                )
                for try await chunk in stream {
                    try Task.checkCancellation()
                    continuation.yield(chunk)
                }
                continuation.finish()
                return
            }

            // Standard decode: split out the system prompt, treat the
            // last user message as the trigger, everything else as
            // history. A trailing non-user / non-tool message (rare —
            // an assistant turn awaiting continuation) folds into
            // history with empty user text; the runner will emit
            // nothing useful but won't crash.
            let split = Self.split(messages: messages)
            await runner.setSystemPrompt(split.system)
            try await runner.setHistory(split.history)
            let stream = await runner.sendUserMessage(
                split.userText, maxTokens: params.maxTokens
            )
            for try await chunk in stream {
                try Task.checkCancellation()
                continuation.yield(chunk)
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private struct Split {
        let system: String?
        let history: [(role: String, content: String)]
        let userText: String
    }

    private static func split(messages: [TranscriptMessage]) -> Split {
        var system: String? = nil
        var history: [(role: String, content: String)] = []
        var userText: String = ""
        for (i, msg) in messages.enumerated() {
            let isLast = (i == messages.count - 1)
            switch msg.role {
            case .system:
                // Multiple system messages collapse into the last one
                // — `setSystemPrompt` is single-valued. Rare in
                // practice; documented here so the behaviour is not a
                // surprise.
                system = msg.content
            case .user:
                if isLast {
                    userText = msg.content
                } else {
                    history.append(("user", msg.content))
                }
            case .assistant:
                history.append(("assistant", msg.content))
            case .tool:
                // Tool messages mid-history (multi-cycle turns) flow
                // through the chat template under their raw role
                // name. Not all model templates recognise `tool` as a
                // role — Llama 3 wants `ipython`. The naive adapter
                // does not translate; users running multi-cycle tool
                // loops through `BasicLoop` against a Llama 3 model
                // should keep the loop to a single cycle, or handle
                // the role mapping in their own runner adapter.
                history.append(("tool", msg.content))
            }
        }
        return Split(system: system, history: history, userText: userText)
    }
}
