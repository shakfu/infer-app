import Foundation

/// One turn in a chat transcript fed to a `ChatRunner`. Mirrors the
/// `(role, content, imageURLs)` tuple shapes that `LlamaRunner.setHistory`
/// / `MLXRunner.setHistory` currently accept on the chat-VM path, but as
/// a first-class `Sendable` value type so it can cross actor boundaries
/// without `@unchecked` workarounds.
public struct ChatTurn: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: String
    public let imageURLs: [URL]

    public init(role: Role, content: String, imageURLs: [URL] = []) {
        self.role = role
        self.content = content
        self.imageURLs = imageURLs
    }
}

/// Narrow chat-side surface that the chat view-model drives. Distilled
/// from the actual `LlamaRunner` / `MLXRunner` / `CloudRunner` chat
/// surface (see `ChatViewModel/Generation.swift` and
/// `ChatViewModel/Transcript.swift`):
///
/// - `setHistory` rebuilds the runner's KV cache / `ChatSession` from the
///   supplied turns. It is the single entry point used by transcript
///   load, edit-and-resend, regenerate, and `<think>`-block compaction.
///   System turns are accepted in-band: each adapter routes them to the
///   underlying runner's system-prompt slot (for `LlamaRunner` that's
///   the dedicated `setSystemPrompt` setter; `MLXRunner` and
///   `CloudRunner` consume them as part of the history).
/// - `respondToUser` returns the assistant stream for the next turn.
///   Cancellation propagates by terminating the stream on the consumer
///   side AND by an explicit `requestStop`. `maxTokens` is the only
///   per-call parameter — sampling (`temperature`, `topP`, `seed`) is
///   set out-of-band on the concrete runner via its own
///   `updateSettings` / `updateSampling` API, mirroring how the chat-VM
///   applies sampling once via `applySettings` rather than per call.
/// - `resetConversation` clears in-runner conversation state but keeps
///   the model loaded.
public protocol ChatRunner: Actor {
    func setHistory(_ turns: [ChatTurn]) async throws
    func respondToUser(_ text: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error>
    func requestStop() async
    func resetConversation() async
    /// Pop the most recent assistant + user pair from the runner's
    /// internal state. Called by the chat-VM's regenerate-last and
    /// edit-and-resend flows so the next `respondToUser` runs against
    /// the same context the prior one did. No-op when the trailing
    /// pair is not `[…, .user, .assistant]`.
    func rewindLastTurn() async
}
