import Foundation
import InferAgents

/// Stateless `AgentRunner` adapter over the stateful `MLXRunner`
/// actor. Mirror of `LlamaRunner+AgentRunner`; lets `BasicLoop` drive
/// MLX-loaded models from CLI / batch / integration tests.
///
/// **Cache caveat.** Like the Llama adapter, this rebuilds the
/// runner's history on every `decode` call (`updateSettings` to push
/// the system prompt, `setHistory` to replace prior turns). MLX's
/// `ChatSession` is cheap to re-instantiate so the absolute cost is
/// lower than llama.cpp's KV reset, but it is still O(history) per
/// call. Acceptable for short / one-shot use cases — not for long
/// interactive sessions.
///
/// **Tool-cycle handling.** When `BasicLoop` re-enters with a
/// trailing `.tool` message, the adapter folds the tool result into
/// the working transcript as a synthetic assistant turn prefixed by
/// "Tool result:" before issuing the next user message. MLX's
/// `ChatSession` does not expose a structured tool-result role; the
/// chat model has to be prompted to interpret the framed text. Models
/// trained with explicit tool-calling templates may need a more
/// specialised adapter to round-trip tool calls cleanly through MLX.
extension MLXRunner: AgentRunner {
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
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.requestStop() }
            }
        }
    }

    private static func performAgentDecode(
        runner: MLXRunner,
        messages: [TranscriptMessage],
        params: DecodingParams,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        // Split system, history, and the trigger user message. A
        // trailing `.tool` message folds into history as a synthetic
        // assistant turn (see type doc) so the next user message
        // carries forward.
        var system: String? = nil
        var history: [(role: String, content: String, imageURLs: [URL])] = []
        var userText: String = ""
        let lastIndex = messages.count - 1
        for (i, msg) in messages.enumerated() {
            switch msg.role {
            case .system:
                system = msg.content
            case .user:
                if i == lastIndex {
                    userText = msg.content
                } else {
                    history.append(("user", msg.content, []))
                }
            case .assistant:
                history.append(("assistant", msg.content, []))
            case .tool:
                if i == lastIndex {
                    // Tool result with no following user turn: surface
                    // it as a final user message that nudges the model
                    // to incorporate the result. Naive but works for
                    // generic chat models that don't recognise a
                    // dedicated tool role.
                    userText = "Tool result: \(msg.content)\n\nContinue your answer using this result."
                } else {
                    history.append((
                        "assistant",
                        "Tool result: \(msg.content)",
                        []
                    ))
                }
            }
        }

        await runner.updateSettings(
            systemPrompt: system,
            temperature: Float(params.temperature),
            topP: Float(params.topP),
            seed: nil
        )
        await runner.setHistory(history)
        let stream = await runner.sendUserMessage(
            userText, imageURLs: [], maxTokens: params.maxTokens
        )
        do {
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
}
