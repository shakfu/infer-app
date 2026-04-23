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
