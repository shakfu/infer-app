import Foundation
import InferAppCore

/// `ChatRunner` conformance for the chat-VM-driven path. Distinct from
/// the `AgentRunner` conformance in `MLXRunner+AgentRunner.swift`
/// (which exposes the stateless `decode(messages:params:)` shape used
/// by `BasicLoop`).
extension MLXRunner: ChatRunner {
    /// MLX accepts system / user / assistant in-band — its existing
    /// `setHistory` handles all three role strings (anything else is
    /// silently dropped). Image URLs from the `ChatTurn` flow into
    /// MLX's per-turn `imageURLs` slot for VLM-capable models.
    public func setHistory(_ turns: [ChatTurn]) async throws {
        let mapped: [(role: String, content: String, imageURLs: [URL])] = turns.map {
            (role: $0.role.rawValue, content: $0.content, imageURLs: $0.imageURLs)
        }
        setHistory(mapped)
    }

    /// MLX captures sampling at `ChatSession` build-time inside
    /// `sendUserMessage`; the chat-VM applies sampling out-of-band via
    /// `updateSettings`, so the protocol surface stays narrow. Image
    /// URLs default to `[]` here — VLM-aware paths go through the
    /// runner directly today; that surface can be lifted onto the
    /// protocol once a second runner needs it.
    public func respondToUser(_ text: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        sendUserMessage(text, imageURLs: [], maxTokens: maxTokens)
    }
}
