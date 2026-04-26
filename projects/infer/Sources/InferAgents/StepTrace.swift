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

    /// Per-turn measurements stamped by the loop driver: net tokens
    /// decoded, wall-clock duration, and per-tool elapsed times. Counts
    /// derivable from `steps` (call count, failure count) are also
    /// surfaced precomputed so the UI doesn't re-walk the step list on
    /// every render. Optional and omitted from the encoded form when
    /// nil so traces written before telemetry was tracked round-trip
    /// unchanged.
    public struct TurnTelemetry: Codable, Equatable, Sendable {
        /// Net (post-think-filter) tokens decoded across all decode
        /// passes for this turn. Zero when the segment was driven by a
        /// `customLoop` agent that never decoded.
        public var tokens: Int
        /// Wall-clock from segment start to terminator, in milliseconds.
        /// Nil when the loop driver didn't measure (legacy traces, or
        /// custom-loop agents that bypass the timing instrumentation).
        public var durationMillis: Int?
        /// Per-tool elapsed time in milliseconds, summed across calls
        /// to the same tool inside a single turn. Empty when the turn
        /// invoked no tools.
        public var toolLatencyMillisByName: [ToolName: Int]
        /// Tool calls emitted this turn (incl. failures). Equivalent
        /// to `steps.filter { case .toolCall }.count` precomputed.
        public var toolCallCount: Int
        /// Tool calls whose result carried an `error` field. Subset of
        /// `toolCallCount`. Useful as a quick "did anything go wrong"
        /// signal in the UI.
        public var toolFailureCount: Int

        public init(
            tokens: Int = 0,
            durationMillis: Int? = nil,
            toolLatencyMillisByName: [ToolName: Int] = [:],
            toolCallCount: Int = 0,
            toolFailureCount: Int = 0
        ) {
            self.tokens = tokens
            self.durationMillis = durationMillis
            self.toolLatencyMillisByName = toolLatencyMillisByName
            self.toolCallCount = toolCallCount
            self.toolFailureCount = toolFailureCount
        }

        /// Add (or merge with summation) one tool's elapsed time. Same
        /// tool called twice in a turn accumulates; the UI surfaces the
        /// total because per-call breakdowns are already visible inside
        /// the trace's step rows.
        public mutating func recordToolLatency(_ name: ToolName, millis: Int) {
            toolLatencyMillisByName[name, default: 0] += millis
        }

        /// Recompute `toolCallCount` and `toolFailureCount` from
        /// `steps`. Called by the loop driver at terminator time so
        /// the precomputed counts always agree with the step list.
        public mutating func refreshCounts(from steps: [Step]) {
            var calls = 0
            var failures = 0
            for step in steps {
                switch step {
                case .toolCall: calls += 1
                case .toolResult(let result): if result.error != nil { failures += 1 }
                default: break
                }
            }
            self.toolCallCount = calls
            self.toolFailureCount = failures
        }
    }

    public var steps: [Step]
    /// Multi-agent attribution, empty for single-agent turns. Decoded
    /// with a default-empty fallback so traces written before this
    /// field existed (M2 era) still round-trip cleanly.
    public var segments: [SegmentSpan]
    /// Per-turn measurements (item 8). Nil when the loop driver didn't
    /// stamp telemetry; the UI degrades gracefully (no chip rendered).
    public var telemetry: TurnTelemetry?

    public init(
        steps: [Step] = [],
        segments: [SegmentSpan] = [],
        telemetry: TurnTelemetry? = nil
    ) {
        self.steps = steps
        self.segments = segments
        self.telemetry = telemetry
    }

    private enum CodingKeys: String, CodingKey {
        case steps
        case segments
        case telemetry
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.steps = try c.decode([Step].self, forKey: .steps)
        self.segments = try c.decodeIfPresent([SegmentSpan].self, forKey: .segments) ?? []
        self.telemetry = try c.decodeIfPresent(TurnTelemetry.self, forKey: .telemetry)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(steps, forKey: .steps)
        // Skip the field in the encoded form when empty so single-agent
        // traces stay byte-identical to their pre-M5 representation.
        if !segments.isEmpty {
            try c.encode(segments, forKey: .segments)
        }
        if let telemetry {
            try c.encode(telemetry, forKey: .telemetry)
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
