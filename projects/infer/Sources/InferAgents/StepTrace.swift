import Foundation

/// Canonical per-turn record of what an agent did.
///
/// A `StepTrace` is an ordered list of `Step`s terminating in one of:
/// `.finalAnswer`, `.cancelled`, `.budgetExceeded`, or `.error`. This is
/// what the transcript renderer reads and what persists with a turn.
///
/// PR 1 only ever emits `.finalAnswer` (no loop, no tools). The other
/// cases are defined now so the persisted format is stable across PRs.
public struct StepTrace: Codable, Equatable, Sendable {
    public enum Step: Codable, Equatable, Sendable {
        /// Plain assistant text emitted between (or instead of) tool calls.
        case assistantText(String)
        case toolCall(ToolCall)
        case toolResult(ToolResult)
        case finalAnswer(String)
        case cancelled
        case budgetExceeded
        case error(String)
    }

    public var steps: [Step]

    public init(steps: [Step] = []) {
        self.steps = steps
    }

    public static func finalAnswer(_ text: String) -> StepTrace {
        StepTrace(steps: [.finalAnswer(text)])
    }

    /// The trace's terminal step, if any. A trace without a terminator is
    /// in-progress (only meaningful inside the loop; persisted traces are
    /// always terminated).
    public var terminator: Step? {
        guard let last = steps.last else { return nil }
        switch last {
        case .finalAnswer, .cancelled, .budgetExceeded, .error:
            return last
        default:
            return nil
        }
    }
}
