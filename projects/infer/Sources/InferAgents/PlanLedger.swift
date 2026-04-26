import Foundation

/// State of a planner agent's in-flight plan.
///
/// Planners (item 10 from the agents review) are dynamic — the model
/// drafts a plan, the loop executes each step, and the planner can
/// revise the remaining steps if one fails. `PlanLedger` is the
/// authoritative state that survives across decode rounds inside one
/// turn: a goal (typically the user input), an ordered list of
/// `PlanStep`s with per-step status + output + error, a cursor
/// pointing at the next step to attempt, and a count of revisions
/// the planner has issued so the loop can cap thrash.
///
/// `Sendable` + `Codable` so the ledger can be embedded in a
/// `StepTrace` for observability and round-tripped through a vault
/// row. Mutators are non-throwing — invalid transitions (completing a
/// step that doesn't exist, advancing past the end) are no-ops rather
/// than errors so a misbehaving model can't crash the planner.
public struct PlanLedger: Codable, Equatable, Sendable {

    public enum StepStatus: String, Codable, Equatable, Sendable {
        /// Drafted but not yet attempted.
        case pending
        /// Currently executing (set by the planner before a tool
        /// invocation). Visible to traces / UIs while a long tool
        /// call is in flight.
        case running
        /// Tool produced a result with no `error`. `output` carries
        /// the tool's output for downstream steps and final synthesis.
        case completed
        /// Tool result carried an `error`, the model failed to emit a
        /// recognised tool call, or the planner gave up after exhausting
        /// the per-step retry budget. `errorMessage` carries the cause.
        case failed
        /// Skipped during a replan (the planner decided this step is
        /// no longer needed). `output` left nil; never re-attempted.
        case skipped
    }

    public struct PlanStep: Codable, Equatable, Sendable {
        /// Stable ordinal — `1`, `2`, `3`, … — assigned at plan
        /// creation. Survives replans (the planner overwrites
        /// description / status / output but the ordinal stays so
        /// trace consumers can follow which step is which).
        public let ordinal: Int
        public var description: String
        public var status: StepStatus
        public var output: String?
        public var errorMessage: String?

        public init(
            ordinal: Int,
            description: String,
            status: StepStatus = .pending,
            output: String? = nil,
            errorMessage: String? = nil
        ) {
            self.ordinal = ordinal
            self.description = description
            self.status = status
            self.output = output
            self.errorMessage = errorMessage
        }
    }

    public var goal: String
    public var steps: [PlanStep]
    /// Index into `steps` of the next step to attempt. Equal to
    /// `steps.count` once the planner has walked past the end.
    public var cursor: Int
    /// How many times the planner has revised the plan during this
    /// turn. Bounded by the agent's `maxReplans` config.
    public var replanCount: Int

    public init(
        goal: String,
        steps: [PlanStep] = [],
        cursor: Int = 0,
        replanCount: Int = 0
    ) {
        self.goal = goal
        self.steps = steps
        self.cursor = cursor
        self.replanCount = replanCount
    }

    public var currentStep: PlanStep? {
        guard cursor >= 0, cursor < steps.count else { return nil }
        return steps[cursor]
    }

    public var isComplete: Bool {
        cursor >= steps.count
    }

    /// True when at least one step finished with `.failed`. The
    /// planner reports a degraded outcome on this signal — the final
    /// answer still gets synthesised, but the host can tell the user
    /// the plan was not entirely successful.
    public var hasFailures: Bool {
        steps.contains { $0.status == .failed }
    }

    // MARK: - Mutators

    /// Mark the current step `running`. No-op when cursor is past
    /// the end (defensive — should not happen during the standard
    /// loop, but a misbehaving planner that calls advance twice
    /// shouldn't crash).
    public mutating func beginCurrentStep() {
        guard cursor < steps.count else { return }
        steps[cursor].status = .running
    }

    /// Mark the current step completed with `output`, then advance
    /// the cursor. No-op when cursor is past the end.
    public mutating func completeCurrentStep(output: String) {
        guard cursor < steps.count else { return }
        steps[cursor].status = .completed
        steps[cursor].output = output
        cursor += 1
    }

    /// Mark the current step failed with `errorMessage`, then advance.
    /// Replan logic is the planner's responsibility (it can call
    /// `revise` to overwrite the rest of the plan); this mutator
    /// just records the failure and moves on so an unrevised plan
    /// still terminates.
    public mutating func failCurrentStep(errorMessage: String) {
        guard cursor < steps.count else { return }
        steps[cursor].status = .failed
        steps[cursor].errorMessage = errorMessage
        cursor += 1
    }

    /// Replace the steps at and after `cursor` with `newSteps`.
    /// Increments `replanCount`. Steps before the cursor (already
    /// attempted) are preserved verbatim — the model is revising the
    /// remaining plan, not rewriting history. Ordinals on the new
    /// steps continue the existing numbering.
    public mutating func revise(remainingSteps newSteps: [String]) {
        let preserved = Array(steps.prefix(cursor))
        var nextOrdinal = (preserved.last?.ordinal ?? 0) + 1
        let revised: [PlanStep] = newSteps.map { description in
            let step = PlanStep(ordinal: nextOrdinal, description: description)
            nextOrdinal += 1
            return step
        }
        self.steps = preserved + revised
        self.replanCount += 1
        // Cursor stays at the same index — the new step at `cursor`
        // is what the planner attempts next.
    }

    /// Render the ledger as a compact, model-readable status block.
    /// Embedded in the per-step decode prompt so the LLM sees what
    /// has already happened, what's queued, and the current goal.
    /// Format: line per step, prefixed by ordinal + status glyph.
    public func renderForPrompt() -> String {
        var lines: [String] = []
        lines.append("Goal: \(goal)")
        lines.append("Plan:")
        for step in steps {
            let glyph: String
            switch step.status {
            case .pending: glyph = "[ ]"
            case .running: glyph = "[~]"
            case .completed: glyph = "[x]"
            case .failed: glyph = "[!]"
            case .skipped: glyph = "[-]"
            }
            lines.append("  \(glyph) \(step.ordinal). \(step.description)")
            if let out = step.output, !out.isEmpty {
                let trimmed = out.count > 200 ? String(out.prefix(200)) + "…" : out
                lines.append("       output: \(trimmed)")
            }
            if let err = step.errorMessage {
                lines.append("       error:  \(err)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Tolerant parser that converts a model's plan response into a list
/// of step descriptions.
///
/// Accepts the loose formats LLMs actually emit:
/// - `1. Do the thing` / `1) Do the thing`
/// - `- Do the thing` / `* Do the thing`
/// - Bare lines separated by newlines (last-resort fallback when no
///   numbering or bullets show up)
///
/// Strips leading numbering / bullets, trims whitespace, drops empty
/// lines and lines that look like prose (no leading marker AND the
/// list has at least one marked entry — keeps a numbered list from
/// being polluted by an introductory sentence). Returns an empty
/// array when nothing recognisable is present, so callers can fall
/// back to a single-step plan with the goal as the description.
public enum PlanParser {
    private static let numberedPrefix = try! NSRegularExpression(
        pattern: #"^\s*\d+[\.)]\s+"#
    )
    private static let bulletPrefix = try! NSRegularExpression(
        pattern: #"^\s*[-*•]\s+"#
    )

    public static func parseSteps(from text: String) -> [String] {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }

        var marked: [String] = []
        var unmarked: [String] = []
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let cleaned = stripPrefix(trimmed, regex: numberedPrefix) {
                marked.append(cleaned)
            } else if let cleaned = stripPrefix(trimmed, regex: bulletPrefix) {
                marked.append(cleaned)
            } else {
                unmarked.append(trimmed)
            }
        }
        if !marked.isEmpty { return marked }
        // Fallback: no numbering or bullets, treat each non-empty
        // line as a step. Drops the introductory "Here's the plan:"
        // line that often shows up alone — single-line responses go
        // through unchanged because there's nothing to drop.
        if unmarked.count > 1, looksLikePreamble(unmarked.first ?? "") {
            return Array(unmarked.dropFirst())
        }
        return unmarked
    }

    private static func stripPrefix(_ line: String, regex: NSRegularExpression) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else {
            return nil
        }
        guard let r = Range(match.range, in: line) else { return nil }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func looksLikePreamble(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasSuffix(":") || lower.contains("here's")
            || lower.contains("plan to") || lower.contains("steps")
    }
}
