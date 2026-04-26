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
        case qwen
        case hermes

        /// Bridge from `TemplateFamily` (the broader classification used
        /// for compatibility checks and prompt composition) to the
        /// parser-relevant subset. `.openai` falls through to `.llama3`
        /// since OpenAI tool-calling has no in-stream syntax — the
        /// closest local-decode shape is Llama 3's `<|python_tag|>`.
        public init(_ template: TemplateFamily) {
            switch template {
            case .llama3, .openai: self = .llama3
            case .qwen: self = .qwen
            case .hermes: self = .hermes
            }
        }
    }

    public let family: Family

    public init(family: Family) {
        self.family = family
    }

    /// Opening tag this parser looks for. Used by the chat view-model
    /// to trim the tool-call portion out of the visible message body
    /// after parsing — `messages[i].text` is the think-filtered stream
    /// already, so we just slice from this tag onwards rather than
    /// re-stamping with `match.prefix` (which is the *raw* prefix and
    /// would re-introduce any filtered `<think>` content).
    public var openTag: String {
        switch family {
        case .llama3: return "<|python_tag|>"
        case .qwen, .hermes: return "<tool_call>"
        }
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
        case .qwen, .hermes:
            // Qwen-2.5/3 and Hermes-3 converged on the same in-stream
            // tool-call shape: `<tool_call>{JSON}</tool_call>`. Kept as
            // separate `Family` cases anyway so the picker's
            // compatibility check distinguishes "agent wants Qwen" from
            // "agent wants Hermes" — useful when fingerprinting later
            // grows finer-grained, and free at parse time.
            return Self.findToolCallTag(in: text)
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

    // MARK: Qwen / Hermes

    /// `<tool_call>{JSON}</tool_call>` with the JSON containing
    /// `name` and either `arguments` (Qwen / Hermes) or `parameters`
    /// (Llama-style fallback). The JSON's `arguments` value can be
    /// either an object (the canonical case) or a stringified object
    /// (some Hermes variants); both round-trip into the parser's
    /// `arguments: String` field.
    static func findToolCallTag(in text: String) -> Match? {
        guard let openRange = text.range(of: "<tool_call>") else {
            return nil
        }
        let prefix = String(text[..<openRange.lowerBound])
        let afterOpen = text[openRange.upperBound...]

        // Locate the closing tag, if any. Without it we can still try
        // to parse what's there — the runner may have stopped on EOS.
        var jsonEnd: String.Index = afterOpen.endIndex
        var sawClose = false
        if let closeRange = afterOpen.range(of: "</tool_call>") {
            jsonEnd = closeRange.lowerBound
            sawClose = true
        }
        let jsonText = afterOpen[..<jsonEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if jsonText.isEmpty && !sawClose { return nil }

        guard
            let data = jsonText.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = obj["name"] as? String,
            !name.isEmpty
        else {
            return nil
        }

        // `arguments` (Qwen/Hermes) preferred, fall back to `parameters`
        // (Llama-shaped) so a model that emits the wrong wrapper still
        // round-trips. Both can be either an object or a JSON string;
        // normalise to the string form the rest of the loop expects.
        let argsValue: Any = obj["arguments"]
            ?? obj["parameters"]
            ?? [String: Any]()
        let argsString = Self.normaliseArgs(argsValue)

        return Match(
            prefix: prefix,
            call: ToolCall(name: name, arguments: argsString)
        )
    }

    /// Convert an `arguments`/`parameters` value — either a JSON object
    /// or an already-stringified one — into the canonical compact JSON
    /// string the rest of the agent layer treats as `ToolCall.arguments`.
    private static func normaliseArgs(_ value: Any) -> String {
        if let s = value as? String {
            // Stringified JSON — validate by re-parsing then
            // re-serialise so the parser's output is sort-stable.
            if let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let out = try? JSONSerialization.data(
                   withJSONObject: obj, options: [.sortedKeys]
               ),
               let normalised = String(data: out, encoding: .utf8) {
                return normalised
            }
            // Not parseable as JSON — return it raw rather than lose it.
            return s
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys]
        ), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}
