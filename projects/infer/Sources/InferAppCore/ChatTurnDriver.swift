import Foundation

/// Runs one user-turn-to-assistant-reply cycle against a `ChatRunner`.
/// The chat-VM's `send()` does roughly this (`Generation.swift`) inside
/// hundreds of lines of additional concerns — composition, segment
/// dispatch, RAG augmentation, agent attribution, `<think>` filtering,
/// KV compaction, vault writes, TTS, voice-loop arming. This kernel
/// owns only the runner-driving slice so it can be tested in isolation
/// against `MockChatRunner`:
///
///   1. Push prior history into the runner via `setHistory`.
///   2. Open the assistant stream via `respondToUser`.
///   3. Forward each chunk to the supplied `onChunk` (synchronous —
///      callers that need a thread hop wrap it).
///   4. Return the assembled reply when the stream finishes.
///
/// **Ordering invariant.** `setHistory` lands strictly before
/// `respondToUser`. Inverted ordering is the F-3-class regression the
/// MLX backend has historically been vulnerable to (settings rebuilds
/// can race the new send and clobber history) — the kernel makes the
/// ordering explicit and tests assert it via the mock's recorded
/// calls.
///
/// **Cancellation.** If the caller cancels the encompassing `Task`,
/// the `for try await` propagates `CancellationError` out of the
/// kernel. The runner's own `requestStop` is the caller's
/// responsibility — call it on the ChatRunner before cancelling the
/// task if you want the runner-side decode loop to short-circuit
/// rather than draining its current batch.
public enum ChatTurnDriver {
    public static func runOneTurn(
        runner: any ChatRunner,
        priorHistory: [ChatTurn],
        userText: String,
        maxTokens: Int,
        onChunk: ((String) -> Void)? = nil
    ) async throws -> String {
        try await runner.setHistory(priorHistory)
        let stream = await runner.respondToUser(userText, maxTokens: maxTokens)
        var assembled = ""
        for try await chunk in stream {
            assembled.append(chunk)
            onChunk?(chunk)
        }
        return assembled
    }
}
