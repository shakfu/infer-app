import Foundation
import InferAppCore
import InferCore

/// Headless, backend-agnostic multi-turn chat engine. Coordinates a
/// `ChatRunner` (cloud today; Llama/MLX once the executable's runners are
/// reachable from a shared target) with a value-typed `TranscriptStore`, so
/// the runner-driving + transcript slice of the app's `ChatViewModel.send()`
/// can run with no SwiftUI, AppKit, or `@Observable` state — drivable from a
/// CLI and testable against `MockChatRunner`.
///
/// This is the seam the SwiftUI view model is meant to delegate to: it owns
/// the same incremental-vs-rebuild distinction `Generation.swift` documents,
/// but expressed against the shared `TranscriptStore` rather than the VM's
/// `@Observable messages: [ChatMessage]`. What it deliberately does NOT own
/// (and what keeps it headless) is the app-only concerns layered on top of
/// `send()`: RAG/wiki augmentation, agent/composition dispatch, vault writes,
/// TTS, and token telemetry. Those stay in the executable target.
///
/// ## Two runner-driving modes
/// - **Incremental** (`send`): append the user turn and call `respondToUser`
///   *without* `setHistory`. All runners accumulate conversation state across
///   `respondToUser` calls (llama KV cache, MLX `history`, cloud `messages`),
///   so re-pushing history every turn would re-prefill from scratch — the
///   multi-hundred-millisecond regression `Generation.swift:48` calls out.
/// - **Rebuild** (`regenerate` / `editAndResend`): mutate the transcript, then
///   `setHistory` the prior turns before `respondToUser`. The rebuild cost is
///   acceptable here because the conversation shape changed.
public actor ChatEngine {
    public let runner: any ChatRunner
    public private(set) var transcript: TranscriptStore

    public init(runner: any ChatRunner, transcript: TranscriptStore = TranscriptStore()) {
        self.runner = runner
        self.transcript = transcript
    }

    /// Send one user turn (incremental mode). Appends the user turn and an
    /// assistant turn to the transcript, streams the reply into the assistant
    /// turn, forwards each chunk to `onChunk`, and returns the assembled reply.
    /// On a thrown error the partial reply collected so far stays in the
    /// transcript and the error is rethrown for the caller to handle.
    @discardableResult
    public func send(
        _ text: String,
        maxTokens: Int = 512,
        netCap: Int = .max,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        transcript.appendUser(text)
        return try await drive(userText: text, rebuildHistory: nil, maxTokens: maxTokens, netCap: netCap, onChunk: onChunk)
    }

    /// Drop the trailing assistant turn and re-run the prior user turn
    /// (rebuild mode). Returns the assembled reply, or nil — with no runner
    /// call — if the transcript does not end in an assistant turn that follows
    /// a user turn.
    @discardableResult
    public func regenerate(
        maxTokens: Int = 512,
        netCap: Int = .max,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String? {
        guard let userText = transcript.regenerate() else { return nil }
        // After `regenerate()` the transcript ends at the user turn; the prior
        // history is everything before it.
        let prior = Array(transcript.turnsForHistory().dropLast())
        return try await drive(userText: userText, rebuildHistory: prior, maxTokens: maxTokens, netCap: netCap, onChunk: onChunk)
    }

    /// Rewrite an earlier user turn, discard everything after it, and re-run
    /// it (rebuild mode). Returns the dropped entries (so the caller can
    /// preserve or discard them), or nil — with no runner call — if `id` is
    /// not a user turn in the transcript.
    @discardableResult
    public func editAndResend(
        messageId id: UUID,
        newText: String,
        maxTokens: Int = 512,
        netCap: Int = .max,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> [TranscriptEntry]? {
        guard let dropped = transcript.editAndResend(messageId: id, newText: newText) else { return nil }
        let prior = Array(transcript.turnsForHistory().dropLast())
        _ = try await drive(userText: newText, rebuildHistory: prior, maxTokens: maxTokens, netCap: netCap, onChunk: onChunk)
        return dropped
    }

    /// Clear the transcript and the runner's conversation state. Keeps any
    /// runner-side configuration (cloud provider/model, loaded local model).
    public func reset() async {
        transcript.reset()
        await runner.resetConversation()
    }

    /// Stop an in-flight `send` / `regenerate` / `editAndResend`.
    public func requestStop() async {
        await runner.requestStop()
    }

    /// Shared runner-driving core. `rebuildHistory == nil` is incremental
    /// mode; a non-nil value pushes that history via `setHistory` first
    /// (rebuild mode). In both modes a fresh assistant turn is opened in the
    /// transcript and populated as the stream arrives.
    private func drive(
        userText: String,
        rebuildHistory: [ChatTurn]?,
        maxTokens: Int,
        netCap: Int,
        onChunk: (@Sendable (String) -> Void)?
    ) async throws -> String {
        if let prior = rebuildHistory {
            try await runner.setHistory(prior)
        }
        let assistantId = transcript.beginAssistant()
        let stream = await runner.respondToUser(userText, maxTokens: maxTokens)
        // Same `<think>`-stripping + net-token-cap kernel the app's
        // `runOneAgentTurn` uses, so the transcript (and any CLI consumer via
        // `onChunk`) gets the visible reply without reasoning blocks. The
        // store has no thinking-text channel, so `onThinking` / `onRawPiece`
        // are no-ops here; `net` is the engine-local cumulative count the cap
        // checks against.
        var net = 0
        let result = try await StreamTurnConsumer.consume(
            stream,
            netCap: netCap,
            onDisplayDelta: { delta in
                self.transcript.appendChunk(delta, to: assistantId)
                onChunk?(delta)
            },
            onThinking: { _, _ in },
            onRawPiece: { _ in },
            onToken: { isNet in if isNet { net += 1 } },
            netCountSoFar: { net },
            requestStop: { await self.runner.requestStop() }
        )
        return result.display
    }
}
