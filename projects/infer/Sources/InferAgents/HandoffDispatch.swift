import Foundation

/// Parser that extracts a structured `agents.handoff` tool call from an
/// agent's turn output. The structured-handoff replacement for the
/// free-text `<<HANDOFF>>` envelope (`HandoffEnvelope`).
///
/// Runtime contract mirrors `OrchestratorDispatch`: the agent emits a
/// tool call to `agents.handoff` whose JSON payload names the `target`
/// peer and the `payload` to pass it as that peer's user turn. The host
/// loop intercepts the call, runs the inert `AgentsHandoffTool` ack to
/// keep the model's tool loop happy, and after the segment terminates
/// scans the trace for the call. When found, the composition driver
/// follows the handoff exactly as it follows a parsed `<<HANDOFF>>`
/// envelope — the structured route is strictly additive, so older agent
/// configs that still emit envelopes keep working.
///
/// Two sources, in priority order:
///
/// 1. **Trace tool calls.** When the runtime tool loop fires
///    `agents.handoff`, the call lands as `StepTrace.Step.toolCall`.
///    We decode its arguments JSON for `target` + `payload`.
/// 2. **Visible final text.** Fallback for runtimes that didn't
///    intercept the tool call — the raw `<tool_call>` / `<|python_tag|>`
///    block survives in the visible body. Same family scan as
///    `OrchestratorDispatch`. Lets a structured handoff round-trip even
///    before every host wires the builtin into its `ToolRegistry`.
public enum HandoffDispatch {
    public struct Resolved: Equatable, Sendable {
        public let target: AgentID
        public let payload: String
    }

    /// Tool name the agent calls to hand off. Constant so the runtime
    /// registration site and the parser agree on a single string.
    public static let handoffToolName: ToolName = "agents.handoff"

    public static func parse(
        outcome: AgentOutcome
    ) -> Resolved? {
        let trace = traceOf(outcome: outcome)

        for step in trace.steps {
            if case .toolCall(let call) = step,
               call.name == handoffToolName,
               let resolved = parseArguments(call.arguments) {
                return resolved
            }
        }

        let text = textOf(outcome: outcome)
        if let raw = extractInvokeJSON(from: text),
           let resolved = parseArguments(raw) {
            return resolved
        }

        return nil
    }

    /// Convenience: scan the assistant's emitted text directly. Used by
    /// callers that don't have an `AgentOutcome` yet (e.g. the chat-VM
    /// loop driver scanning the visible body before synthesising the
    /// outcome).
    public static func parse(text: String) -> Resolved? {
        if let raw = extractInvokeJSON(from: text),
           let resolved = parseArguments(raw) {
            return resolved
        }
        return nil
    }

    // MARK: - Helpers

    private static func traceOf(outcome: AgentOutcome) -> StepTrace {
        switch outcome {
        case .completed(_, let trace),
             .handoff(_, _, let trace),
             .abandoned(_, let trace),
             .failed(_, let trace):
            return trace
        }
    }

    private static func textOf(outcome: AgentOutcome) -> String {
        switch outcome {
        case .completed(let text, _): return text
        case .handoff(_, _, _): return ""
        case .abandoned, .failed: return ""
        }
    }

    /// Decode `arguments` for `target` (or `agentID` / `agent` /
    /// `agent_id`) + `payload` (or `input` / `message`). Returns nil on
    /// bad JSON, missing fields, or empty target. Tolerant on key
    /// names because models drift; the tool's authored description
    /// uses `target`/`payload` but accepting nearby synonyms keeps the
    /// turn from blowing up on a stray `agentID`.
    private static func parseArguments(_ arguments: String) -> Resolved? {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let rawTarget = (obj["target"] as? String)
            ?? (obj["agentID"] as? String)
            ?? (obj["agent"] as? String)
            ?? (obj["agent_id"] as? String)
        guard let rawTarget, !rawTarget.isEmpty else { return nil }
        let payload = (obj["payload"] as? String)
            ?? (obj["input"] as? String)
            ?? (obj["message"] as? String)
            ?? ""
        return Resolved(target: AgentID(rawTarget), payload: payload)
    }

    private static func extractInvokeJSON(from text: String) -> String? {
        if let r = extractBetween(text, open: "<tool_call>", close: "</tool_call>") {
            return objectOnly(r)
        }
        if let r = extractBetween(text, open: "<|python_tag|>", close: "<|eom_id|>")
            ?? extractBetween(text, open: "<|python_tag|>", close: "<|eot_id|>") {
            return objectOnly(r)
        }
        return nil
    }

    private static func extractBetween(_ text: String, open: String, close: String) -> String? {
        guard let openR = text.range(of: open) else { return nil }
        let after = text[openR.upperBound...]
        guard let closeR = after.range(of: close) else { return nil }
        return String(after[..<closeR.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func objectOnly(_ rawJSON: String) -> String? {
        guard let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let name = obj["name"] as? String, name != handoffToolName {
            return nil
        }
        let inner = obj["arguments"] ?? obj["parameters"] ?? [String: Any]()
        guard let innerData = try? JSONSerialization.data(
            withJSONObject: inner, options: [.sortedKeys]
        ),
              let s = String(data: innerData, encoding: .utf8) else { return nil }
        return s
    }
}
