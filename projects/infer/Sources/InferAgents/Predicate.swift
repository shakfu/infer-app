import Foundation

/// Boolean condition over an `AgentOutcome`, used by composition
/// primitives (`branch`, `refine`) to decide which way to dispatch
/// next. Five cases map to `agent_composition.md` §"Predicates":
///
/// - `regex(pattern)` — assistant text matches the regex.
/// - `jsonShape(requiredKeys)` — assistant text parses as JSON object
///   with all listed top-level keys present (any value type).
/// - `toolCalled(name)` — the segment's trace contains a tool call to
///   `name`.
/// - `noToolCalls` — the segment's trace contains no tool calls.
/// - `stepBudgetExceeded` — the composition's step budget reached zero.
///
/// Predicates are *data*: they decode from JSON and evaluate against
/// outcomes purely. The composition driver passes the predicate +
/// outcome + remaining budget to `evaluate`; no I/O, no side effects.
public enum Predicate: Equatable, Sendable {
    case regex(pattern: String)
    case jsonShape(requiredKeys: [String])
    case toolCalled(name: ToolName)
    case noToolCalls
    case stepBudgetExceeded

    /// Returns true when the predicate matches against `outcome` /
    /// `remainingBudget`. Evaluation is total — invalid regex patterns
    /// or non-JSON text simply return false rather than throwing, so a
    /// composition can't crash on a malformed predicate.
    public func evaluate(
        outcome: AgentOutcome,
        remainingBudget: Int
    ) -> Bool {
        switch self {
        case .regex(let pattern):
            let text = Self.text(of: outcome)
            guard let re = try? NSRegularExpression(pattern: pattern) else {
                return false
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return re.firstMatch(in: text, range: range) != nil

        case .jsonShape(let required):
            let text = Self.text(of: outcome)
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return required.allSatisfy { obj[$0] != nil }

        case .toolCalled(let name):
            return Self.steps(of: outcome).contains { step in
                if case .toolCall(let call) = step, call.name == name { return true }
                return false
            }

        case .noToolCalls:
            return !Self.steps(of: outcome).contains { step in
                if case .toolCall = step { return true }
                return false
            }

        case .stepBudgetExceeded:
            return remainingBudget <= 0
        }
    }

    private static func text(of outcome: AgentOutcome) -> String {
        switch outcome {
        case .completed(let text, _): return text
        case .handoff(_, _, _): return ""
        case .abandoned, .failed: return ""
        }
    }

    private static func steps(of outcome: AgentOutcome) -> [StepTrace.Step] {
        switch outcome {
        case .completed(_, let trace),
             .handoff(_, _, let trace),
             .abandoned(_, let trace),
             .failed(_, let trace):
            return trace.steps
        }
    }
}

// MARK: - Codable

extension Predicate: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, pattern, requiredKeys, name
    }

    private enum Kind: String, Codable {
        case regex, jsonShape, toolCalled, noToolCalls, stepBudgetExceeded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .regex:
            self = .regex(pattern: try c.decode(String.self, forKey: .pattern))
        case .jsonShape:
            self = .jsonShape(requiredKeys: try c.decode([String].self, forKey: .requiredKeys))
        case .toolCalled:
            self = .toolCalled(name: try c.decode(ToolName.self, forKey: .name))
        case .noToolCalls:
            self = .noToolCalls
        case .stepBudgetExceeded:
            self = .stepBudgetExceeded
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .regex(let pattern):
            try c.encode(Kind.regex, forKey: .kind)
            try c.encode(pattern, forKey: .pattern)
        case .jsonShape(let keys):
            try c.encode(Kind.jsonShape, forKey: .kind)
            try c.encode(keys, forKey: .requiredKeys)
        case .toolCalled(let name):
            try c.encode(Kind.toolCalled, forKey: .kind)
            try c.encode(name, forKey: .name)
        case .noToolCalls:
            try c.encode(Kind.noToolCalls, forKey: .kind)
        case .stepBudgetExceeded:
            try c.encode(Kind.stepBudgetExceeded, forKey: .kind)
        }
    }
}
