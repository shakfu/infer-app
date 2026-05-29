import Foundation

/// The think-filter + net-token-cap stream-consumption loop, extracted from
/// `ChatViewModel.runOneAgentTurn` so the exact same logic can drive both the
/// SwiftUI app's `messages[i]` and the headless `ChatEngine`'s transcript.
///
/// The loop is backend- and agent-agnostic: every turn (llama / MLX / cloud,
/// Default agent or composed) consumes the runner stream identically — strip
/// `<think>…</think>` reasoning into a side channel, count tokens, and stop
/// the runner once the *visible* reply reaches the user's cap. The caller
/// projects the deltas onto its own state via callbacks; the kernel knows
/// nothing about `ChatMessage`, `TranscriptStore`, actors, or SwiftUI.
///
/// ## Net-token cap ownership
/// The cap is checked against `netCountSoFar()` — the *caller's* cumulative
/// net-visible count — not a kernel-local counter, because the app's
/// `netTokenCount` spans every segment of a user turn (composition chains run
/// several runner turns under one cap). The caller increments its counter in
/// `onToken` and reports it back; the kernel only contributes the
/// `!inThink` half of the condition (a closing `</think>` must be seen before
/// the first net token counts).
public enum StreamTurnConsumer {
    /// Consume `stream`, returning the think-stripped visible text and the
    /// accumulated thinking text. Rethrows whatever the stream throws (the
    /// caller maps cancellation / errors to its own outcome type).
    ///
    /// Callback order per decoded piece mirrors the original inline loop:
    /// display delta (only when non-empty) → thinking update (every piece) →
    /// raw piece → token tick → cap check. The flushed tail is appended to
    /// the display and reported via `onDisplayDelta`, but is not a decoded
    /// piece so it does not tick `onToken` / `onRawPiece`.
    /// `isolation` inherits the caller's actor (the `#isolation` default), so
    /// the callbacks — which capture the caller's actor-isolated state
    /// (`ChatViewModel.messages` on `@MainActor`, `ChatEngine`'s transcript on
    /// its actor) — run on that same actor with no hop and no data race.
    @discardableResult
    public static func consume(
        _ stream: AsyncThrowingStream<String, Error>,
        netCap: Int,
        onDisplayDelta: (String) async -> Void,
        onThinking: (_ thinking: String, _ inThink: Bool) async -> Void,
        onRawPiece: (String) async -> Void,
        onToken: (_ producedNetVisible: Bool) async -> Void,
        netCountSoFar: () async -> Int,
        requestStop: () async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> (display: String, thinking: String) {
        var filter = ThinkBlockStreamFilter()
        var display = ""
        for try await piece in stream {
            let shown = filter.feed(piece)
            if !shown.isEmpty {
                display += shown
                await onDisplayDelta(shown)
            }
            await onThinking(filter.thinking, filter.inThink)
            await onRawPiece(piece)
            await onToken(!shown.isEmpty)
            if await netCountSoFar() >= netCap, !filter.inThink {
                await requestStop()
                break
            }
        }
        let tail = filter.flush()
        if !tail.isEmpty {
            display += tail
            await onDisplayDelta(tail)
        }
        await onThinking(filter.thinking, false)
        return (display, filter.thinking)
    }
}
