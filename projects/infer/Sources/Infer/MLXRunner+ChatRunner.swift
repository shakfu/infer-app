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
    /// `updateSettings`, so the protocol surface stays narrow.
    public func respondToUser(_ text: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        sendUserMessage(text, imageURLs: [], maxTokens: maxTokens)
    }

    /// The one runner with a real multimodal path, so the only one that
    /// overrides the protocol's default (which drops images). This is
    /// what the generation path now calls; before `imageURLs` was lifted
    /// onto `ChatRunner`, `send()` had to reach for `MLXRunner`
    /// concretely to pass an attachment through.
    public func respondToUser(
        _ text: String,
        imageURLs: [URL],
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        sendUserMessage(text, imageURLs: imageURLs, maxTokens: maxTokens)
    }
}
