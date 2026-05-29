import Foundation
import InferAppCore
import InferCore

/// `ChatRunner` conformance for the hosted-API runner. `CloudRunner`
/// itself lives in `InferCore` (so it can be unit-tested without
/// pulling in the app target's MLX / llama / SwiftUI dependencies);
/// the conformance lives here in `Infer` because `InferAppCore`
/// (which owns the `ChatRunner` protocol) is a leaf target the chat
/// app depends on, not the other way around. Adding the conformance
/// in this file keeps the dependency arrows pointing inward without
/// asking `InferCore` to depend on `InferAppCore`.
extension CloudRunner: ChatRunner {
    /// Cloud manages its system prompt via `configure` /
    /// `updateSettings`; the underlying `setHistory` only accepts
    /// `user` / `assistant` (other roles are dropped). Drop system
    /// turns at the adapter boundary so the leading-system-turn
    /// convention adopted by the protocol is honoured without
    /// double-applying — the chat-VM's load path passes the system
    /// prompt through `configure`.
    public func setHistory(_ turns: [ChatTurn]) async throws {
        let mapped: [(role: String, content: String)] = turns.compactMap {
            switch $0.role {
            case .user, .assistant:
                return (role: $0.role.rawValue, content: $0.content)
            case .system, .tool:
                return nil
            }
        }
        setHistory(mapped)
    }

    public func respondToUser(_ text: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        sendUserMessage(text, maxTokens: maxTokens)
    }
}
