import Foundation

/// Live signal of what an agent is doing during a single turn.
///
/// `AgentEvent` is the public seam between the loop driver and any
/// observer that wants to react in real time — the chat view-model
/// (which keeps `ChatMessage.steps` in sync), the streaming
/// disclosure UI (which needs to know when a tool call is in flight),
/// transcript exporters (which want a full trace), and tests (which
/// assert sequences).
///
/// The event stream is *additional* to the persisted `StepTrace`: every
/// event a consumer needs to reconstruct the trace is here, but events
/// like `toolRunning` exist only to drive UI state (a spinner between
/// `toolRequested` and `toolResulted`) and have no `StepTrace.Step`
/// counterpart. Applying the bytewise-trace-relevant events in order
/// produces a `StepTrace` indistinguishable from the pre-event-stream
/// implementation — see `AgentEventTests.bytewiseFinalTrace`.
public enum AgentEvent: Sendable, Equatable {
    /// Streamed chunk of plain assistant text from the *first* decode of
    /// a turn (before any tool call resolves). Consumers append to the
    /// visible message body. Not yet emitted in M2 — the first decode
    /// streams directly through the runner's `AsyncThrowingStream` in
    /// `ChatViewModel.send`. Reserved here so adding emission later is
    /// non-breaking.
    case assistantChunk(String)

    /// First decode resolved to a tool call. `prefix` is the visible
    /// assistant text emitted *before* the tool tokens (often empty);
    /// the tool tokens themselves are stripped from the rendered body.
    /// Consumer: set `messages[i].text = prefix` and append the
    /// `assistantText(prefix)` (when non-empty) and `.toolCall(call)`
    /// step pair.
    case toolRequested(prefix: String, call: ToolCall)

    /// Tool invocation has begun. UI-only: drives the "running X…"
    /// spinner row in `StepTraceDisclosure` (M3). Emitting consumers
    /// must NOT append a `StepTrace.Step` for this event — adding one
    /// would break the bytewise compatibility with the pre-event-stream
    /// trace shape.
    case toolRunning(name: ToolName)

    /// Tool invocation produced a `ToolResult` (success or error).
    /// Consumer appends `.toolResult(result)` to the trace.
    case toolResulted(ToolResult)

    /// Streamed chunk of the *second* decode (after a tool result has
    /// been fed back). Consumer appends to visible body; the accumulated
    /// text terminates as `.finalAnswer` once `terminated` fires.
    case finalChunk(String)

    /// Terminal event for a turn: one of `.finalAnswer`, `.cancelled`,
    /// `.budgetExceeded`, `.error`. Consumer appends the step to the
    /// trace. Always the last event for a given turn.
    case terminated(StepTrace.Step)

    /// Apply this event's persisted-trace effect to `trace`, in place.
    ///
    /// Only events that map to a `StepTrace.Step` write anything; UI-only
    /// signals (`assistantChunk`, `toolRunning`, `finalChunk`) are no-ops
    /// here. The mapping is exactly what the pre-event-stream
    /// implementation in `ChatViewModel.maybeRunToolLoop` did inline,
    /// extracted so a unit test can assert bytewise compatibility
    /// without driving the runner.
    public func applyToTrace(_ trace: inout StepTrace) {
        switch self {
        case .assistantChunk, .toolRunning, .finalChunk:
            break
        case .toolRequested(let prefix, let call):
            if !prefix.isEmpty {
                trace.steps.append(.assistantText(prefix))
            }
            trace.steps.append(.toolCall(call))
        case .toolResulted(let result):
            trace.steps.append(.toolResult(result))
        case .terminated(let step):
            trace.steps.append(step)
        }
    }
}
