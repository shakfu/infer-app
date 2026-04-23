import Foundation

/// Parser for in-stream tool-call syntax emitted by the model.
///
/// One instance per supported template family. PR 2 ships `.llama3`
/// only; `.qwen` and `.hermes` land in PR 3. The parser is a pure
/// function over the accumulated assistant text: callers feed the full
/// text seen so far (or a long enough tail to span any single call)
/// and receive a structured match, or nil if no complete call is yet
/// present. This keeps the implementation incremental-safe: a partial
/// tool-call tag simply returns nil and the caller waits for more
/// tokens.
public struct ToolCallParser: Sendable {
    public enum Family: String, Sendable, CaseIterable {
        case llama3
    }

    public let family: Family

    public init(family: Family) {
        self.family = family
    }

    /// A located tool call inside a stream of assistant text.
    public struct Match: Equatable, Sendable {
        /// Text that appeared before the tool-call tag. Safe to render
        /// verbatim to the user — it is the assistant's commentary
        /// preceding the call.
        public let prefix: String
        /// The parsed tool call.
        public let call: ToolCall

        public init(prefix: String, call: ToolCall) {
            self.prefix = prefix
            self.call = call
        }
    }

    /// Look for the first complete tool call in `text`. Returns nil if
    /// no tool-call tag is present or if the tag is present but not yet
    /// terminated (the caller should keep accumulating). Malformed
    /// payloads (unparseable JSON, missing `name`) also return nil —
    /// the loop treats a non-parse as "not a tool call," so the raw
    /// text flows through to the user. We deliberately err toward
    /// surface-and-show rather than swallow-and-lose.
    public func findFirstCall(in text: String) -> Match? {
        switch family {
        case .llama3:
            return Self.findLlama3Call(in: text)
        }
    }

    // MARK: Llama 3.1

    /// Llama 3.1 Instruct format: `<|python_tag|>` followed by a JSON
    /// object with `name` and `parameters`, terminated by `<|eom_id|>`
    /// or `<|eot_id|>`. When no terminator is present we still try to
    /// parse, so a stream ending on a well-formed JSON (stop token
    /// already consumed upstream) still matches.
    static func findLlama3Call(in text: String) -> Match? {
        guard let tagRange = text.range(of: "<|python_tag|>") else {
            return nil
        }
        let prefix = String(text[..<tagRange.lowerBound])
        let afterTag = text[tagRange.upperBound...]

        // Locate the earliest terminator, if any.
        let terminators = ["<|eom_id|>", "<|eot_id|>"]
        var jsonEnd: String.Index = afterTag.endIndex
        var sawTerminator = false
        for t in terminators {
            if let r = afterTag.range(of: t), r.lowerBound < jsonEnd {
                jsonEnd = r.lowerBound
                sawTerminator = true
            }
        }
        let jsonText = afterTag[..<jsonEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty body with no terminator => still accumulating.
        if jsonText.isEmpty && !sawTerminator { return nil }

        guard
            let data = jsonText.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = obj["name"] as? String,
            !name.isEmpty
        else {
            // Not yet parseable: either incomplete JSON (wait for more
            // tokens) or malformed (will stay nil even on more data —
            // caller will eventually hit EOS and surface the raw text).
            return nil
        }

        let paramsValue: Any = obj["parameters"] ?? [String: Any]()
        let argsString: String
        if let paramsData = try? JSONSerialization.data(
            withJSONObject: paramsValue,
            options: [.sortedKeys]
        ), let s = String(data: paramsData, encoding: .utf8) {
            argsString = s
        } else {
            argsString = "{}"
        }

        return Match(
            prefix: prefix,
            call: ToolCall(name: name, arguments: argsString)
        )
    }
}
