import Foundation

/// Parser that extracts a router agent's "dispatch to candidate" decision
/// from its turn output.
///
/// M5c orchestrator semantics: the router runs against the user text
/// with a synthetic `agents.invoke` tool exposed. It emits a tool call
/// whose JSON payload names a candidate (`agentID`) and the input to
/// hand it (`input`). `CompositionController.runOrchestrator` consults
/// this parser to extract that decision; if the router didn't emit a
/// recognisable dispatch (or named a non-candidate), the orchestrator
/// surfaces the router's output directly instead of looping forever.
///
/// The parser checks two sources, in order:
///
/// 1. **The trace's tool calls.** When the runtime tool loop is wired
///    to handle `agents.invoke` (Phase B+ tool-loop integration; see
///    M5c task), the call appears as a `StepTrace.Step.toolCall`. We
///    decode its arguments JSON for `agentID` + `input`.
///
/// 2. **The visible final text.** Fallback for the case where the
///    runtime didn't intercept the tool call — the router's emitted
///    `<tool_call>{...}</tool_call>` (or Llama 3 `<|python_tag|>`)
///    block survives in the visible body. The parser scans for either
///    syntax. This makes the orchestrator usable end-to-end even
///    before we register a real `agents.invoke` BuiltinTool.
public enum OrchestratorDispatch {
    public struct Resolved: Equatable, Sendable {
        public let target: AgentID
        public let input: String
    }

    /// Tool name the router calls to dispatch. Constant so the
    /// runtime registration site (when one lands) can use the same
    /// string the parser looks for.
    public static let invokeToolName: ToolName = "agents.invoke"

    public static func parse(
        routerOutcome: AgentOutcome,
        candidates: [AgentID]
    ) -> Resolved? {
        let candidateSet = Set(candidates)
        let trace = traceOf(outcome: routerOutcome)

        // 1. Look for an `agents.invoke` tool call in the trace.
        for step in trace.steps {
            if case .toolCall(let call) = step,
               call.name == invokeToolName,
               let resolved = parseArguments(call.arguments, candidates: candidateSet) {
                return resolved
            }
        }

        // 2. Fallback: scan the visible text for a raw invoke call in
        // either Llama 3 (`<|python_tag|>...<|eom_id|>`) or Qwen/Hermes
        // (`<tool_call>...</tool_call>`) syntax.
        let text = textOf(outcome: routerOutcome)
        if let raw = extractInvokeJSON(from: text),
           let resolved = parseArguments(raw, candidates: candidateSet) {
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

    /// Decode `arguments` (the tool call's JSON payload) into a
    /// `Resolved` if it has `agentID` (or `agent`) + `input` and the
    /// target is in `candidates`. Returns nil on bad JSON, missing
    /// fields, or non-candidate target.
    private static func parseArguments(
        _ arguments: String,
        candidates: Set<AgentID>
    ) -> Resolved? {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let target = (obj["agentID"] as? String)
            ?? (obj["agent"] as? String)
            ?? (obj["agent_id"] as? String)
        guard let target, !target.isEmpty, candidates.contains(target) else {
            return nil
        }
        let input = (obj["input"] as? String) ?? ""
        return Resolved(target: target, input: input)
    }

    /// Pull the arguments JSON out of a router's visible text when the
    /// runtime didn't intercept the tool call. Tries both family
    /// syntaxes; returns the inner JSON object as a string, or nil.
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

    /// The wrapper carries `{"name": "agents.invoke", "arguments": {...}}`
    /// (qwen/hermes) or `{"name": "...", "parameters": {...}}` (llama).
    /// We want the inner object only — pull `arguments` or `parameters`
    /// out and re-serialise it as a flat string the JSON arg parser
    /// can decode.
    private static func objectOnly(_ rawJSON: String) -> String? {
        guard let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Guard the tool name where present.
        if let name = obj["name"] as? String, name != invokeToolName {
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
