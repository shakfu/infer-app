import Foundation

/// Returns the current time as an ISO-8601 string. Zero arguments.
///
/// The simplest possible tool — useful for verifying the loop runs at
/// all (round-trip: model emits a tool call, we produce a real-world
/// value the model couldn't know otherwise, model incorporates it).
public struct ClockNowTool: BuiltinTool {
    public let name: ToolName = "builtin.clock.now"

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Returns the current date and time as an ISO 8601 string (UTC). Call with an empty parameters object: {}."
        )
    }

    /// Hook for tests to pin the clock. Nil = real time.
    let fixedDate: Date?

    public init(fixedDate: Date? = nil) {
        self.fixedDate = fixedDate
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = fixedDate ?? Date()
        return ToolResult(output: formatter.string(from: now))
    }
}

/// Synthetic dispatch tool used by orchestrator agents (M5c).
///
/// The router agent emits a tool call to `agents.invoke` whose arguments
/// name the candidate to dispatch to and the input to hand it. The tool
/// itself is **inert** — it returns a short acknowledgement so the
/// runtime tool loop has something to feed back as ipython/tool input
/// and the router can produce a closing turn. The actual cross-agent
/// dispatch happens *after* the router's segment completes:
/// `CompositionController.runOrchestrator` reads the trace, sees this
/// tool call (via `OrchestratorDispatch.parse`), and runs the chosen
/// candidate as a follow-on segment.
///
/// The two-step design (call here, dispatch in the controller) keeps
/// the tool stateless and stateless-tool-registerable — `BuiltinTool`
/// has no per-call composition context, and we don't want one. Routers
/// must include `agents.invoke` in their `toolsAllow`; the candidate
/// list itself is enumerated in the router agent's authored system
/// prompt so the model knows which targets are valid.
public struct AgentsInvokeTool: BuiltinTool {
    public let name: ToolName = "agents.invoke"

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Dispatch a follow-up turn to one of the candidate agents listed in your system prompt. Arguments: {\"agentID\": \"<candidate id>\", \"input\": \"<the message to send the candidate>\"}. The candidate's reply replaces yours as the user-visible answer."
        )
    }

    public init() {}

    public func invoke(arguments: String) async throws -> ToolResult {
        // Inert: composition driver reads the call from the trace
        // post-segment and follows through with the actual dispatch.
        // The ack here is what the router sees as feedback so it can
        // close the turn cleanly; the user never sees this string
        // because the candidate's reply replaces the router's output.
        ToolResult(output: "dispatch acknowledged")
    }
}

/// Counts whitespace-separated tokens in a string passed as
/// `{"text": "..."}`. No network, no I/O. Useful as the second demo
/// tool because it exercises argument decoding (unlike `clock.now`).
public struct WordCountTool: BuiltinTool {
    public let name: ToolName = "builtin.text.wordcount"

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Counts whitespace-separated words in a passage of text. Arguments: {\"text\": \"<the passage>\"}. Returns the count as a decimal integer."
        )
    }

    public init() {}

    private struct Args: Decodable {
        let text: String
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        guard let data = arguments.data(using: .utf8) else {
            return ToolResult(output: "", error: "arguments not UTF-8")
        }
        do {
            let parsed = try JSONDecoder().decode(Args.self, from: data)
            let count = parsed.text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .count
            return ToolResult(output: String(count))
        } catch {
            return ToolResult(
                output: "",
                error: "could not parse arguments: \(error.localizedDescription)"
            )
        }
    }
}
