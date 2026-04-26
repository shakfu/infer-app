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

    /// Span attributing a contiguous range of `steps` to a single
    /// agent inside a composition. Empty for single-agent turns
    /// (no composition, all steps belong to the active agent on the
    /// row's `agentId`). Composition runtime (M5a-runtime) appends
    /// a span each time control transfers between agents — chain
    /// boundary, fallback hop, orchestrator dispatch.
    ///
    /// `endStep` is exclusive and points one past the last step in
    /// the span, mirroring `Range`'s semantics. Spans are listed in
    /// emit order; they tile (no gaps) but never overlap.
    public struct SegmentSpan: Codable, Equatable, Sendable {
        public let agentId: AgentID
        public let startStep: Int
        public let endStep: Int

        public init(agentId: AgentID, startStep: Int, endStep: Int) {
            self.agentId = agentId
            self.startStep = startStep
            self.endStep = endStep
        }
    }

    public var steps: [Step]
    /// Multi-agent attribution, empty for single-agent turns. Decoded
    /// with a default-empty fallback so traces written before this
    /// field existed (M2 era) still round-trip cleanly.
    public var segments: [SegmentSpan]

    public init(steps: [Step] = [], segments: [SegmentSpan] = []) {
        self.steps = steps
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey {
        case steps
        case segments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.steps = try c.decode([Step].self, forKey: .steps)
        self.segments = try c.decodeIfPresent([SegmentSpan].self, forKey: .segments) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(steps, forKey: .steps)
        // Skip the field in the encoded form when empty so single-agent
        // traces stay byte-identical to their pre-M5 representation.
        if !segments.isEmpty {
            try c.encode(segments, forKey: .segments)
        }
    }

    public static func finalAnswer(_ text: String) -> StepTrace {
        StepTrace(steps: [.finalAnswer(text)])
    }

    /// Find the agent whose `SegmentSpan` covers `stepIndex`, or nil
    /// when the trace has no segments (single-agent turn — every step
    /// belongs to the message-level `agentId` already). Spans are
    /// expected to tile the trace with no gaps and no overlap; the
    /// linear scan is fine because spans rarely exceed a handful per
    /// turn. Promoted from a local helper in the transcript renderer
    /// so non-UI callers (composition tests, exporters) can attribute
    /// steps without duplicating the logic.
    public func agentId(forStepAt stepIndex: Int) -> AgentID? {
        guard !segments.isEmpty else { return nil }
        for span in segments where stepIndex >= span.startStep && stepIndex < span.endStep {
            return span.agentId
        }
        return nil
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
