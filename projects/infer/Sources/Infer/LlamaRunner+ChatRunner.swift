import Foundation
import InferAppCore

/// `ChatRunner` conformance for the chat-VM-driven path. Distinct from
/// the `AgentRunner` conformance in `LlamaRunner+AgentRunner.swift` —
/// `AgentRunner` is the stateless `decode(messages:params:)` shape used
/// by `BasicLoop`; `ChatRunner` is the stateful `setHistory` +
/// `sendUserMessage` shape the chat-VM uses (and which preserves the
/// KV cache across turns instead of re-establishing it on every call).
extension LlamaRunner: ChatRunner {
    /// Llama keeps the system prompt out-of-band via `setSystemPrompt`.
    /// Pull system turns off the front of `turns` and apply them
    /// separately; the underlying `setSystemPrompt` is single-valued so
    /// only the last system turn (if multiple are passed) survives —
    /// matches the contract documented on `LlamaRunner+AgentRunner.swift`.
    public func setHistory(_ turns: [ChatTurn]) async throws {
        var system: String? = nil
        var rest: [(role: String, content: String)] = []
        for t in turns {
            if t.role == .system {
                system = t.content
            } else {
                rest.append((role: t.role.rawValue, content: t.content))
            }
        }
        setSystemPrompt(system)
        try setHistory(rest)
    }

    /// Per-call sampling is intentionally NOT applied here — the
    /// chat-VM updates Llama's sampler once via `applySettings`
    /// (`ChatViewModel/Settings.swift`). The protocol's `maxTokens` is
    /// the only per-call parameter that flows through.
    public func respondToUser(_ text: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        sendUserMessage(text, maxTokens: maxTokens)
    }
}
