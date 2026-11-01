import Foundation

/// Extracts values from JSON with a JSONPath subset: `.a.b`, `.a[0]`,
/// `.a[*].b`, `["dotted.key"]`, and `.` for the root.
///
/// Takes a `url` as well as inline `json`. Passing only `json` would make the
/// model copy a body it already holds into its arguments, which adds context
/// instead of saving it. `url` goes through `http.fetch`, so that tool's host
/// allowlist and size cap apply.
public struct JSONQueryTool: BuiltinTool {
    public let name: ToolName = "json.query"

    /// Cap on returned bytes, matching `fs.read`.
    public static let maxBytes = 64 * 1024

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Extract values from JSON. Arguments: {\"query\": \"<path>\", \"url\": \"https://<host>/<path>\"} or {\"query\": \"<path>\", \"json\": \"<JSON text>\"}. Prefer `url` when the JSON has not been fetched yet, so the full body stays out of the conversation; the host must be on the http.fetch allowlist. Path syntax: `.foo.bar`, `.foo[0]`, `.foo[*].bar`, `[\"dotted.key\"]`, `.` for the root. A string result is returned as plain text and anything else as JSON. `[*]` returns an array and skips elements with no match. Returns up to \(Self.maxBytes) bytes."
        )
    }

    /// Resolves `url` arguments. Nil makes `url` an error.
    public let fetcher: URLFetchTool?

    public init(fetcher: URLFetchTool? = nil) {
        self.fetcher = fetcher
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        guard let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)),
              let args = object as? [String: Any]
        else {
            return ToolResult(output: "", error: "could not parse arguments as a JSON object")
        }
        guard let query = args["query"] as? String else {
            return ToolResult(output: "", error: "missing string argument: query")
        }
        let segments: [Segment]
        do {
            segments = try Self.parse(query)
        } catch {
            return ToolResult(output: "", error: "\(error)")
        }

        let root: Any
        switch (args["json"], args["url"] as? String) {
        case (nil, nil), (.some, .some):
            return ToolResult(output: "", error: "pass exactly one of json or url")
        case (.some(let inline), nil):
            // Models often send the JSON as a nested value, not a string.
            guard let text = inline as? String else {
                root = inline
                break
            }
            guard let parsed = Self.decode(text) else {
                return ToolResult(output: "", error: "json argument is not valid JSON")
            }
            root = parsed
        case (nil, .some(let url)):
            guard let fetcher else {
                return ToolResult(output: "", error: "url is not available: http.fetch is not configured")
            }
            let fetched = try await fetcher.invoke(arguments: Self.fetchArguments(url: url))
            if let error = fetched.error {
                return ToolResult(output: "", error: error)
            }
            // `http.fetch` output is `Content-Type: <mime>\n\n<body>`.
            let body = fetched.output.range(of: "\n\n").map { String(fetched.output[$0.upperBound...]) } ?? ""
            guard let parsed = Self.decode(body) else {
                return ToolResult(output: "", error: "response is not valid JSON, or exceeded the \(URLFetchTool.maxBytes)-byte http.fetch cap")
            }
            root = parsed
        }

        do {
            return ToolResult(output: try Self.render(Self.evaluate(segments, on: root)))
        } catch {
            return ToolResult(output: "", error: "\(error)")
        }
    }

    private static func decode(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private static func fetchArguments(url: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["url": url])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: - Path

    enum Segment: Equatable {
        case key(String)
        case index(Int)
        case wildcard
    }

    struct QueryError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ query: String) throws -> [Segment] {
        var chars = Array(query.trimmingCharacters(in: .whitespaces))
        if chars.first == "$" { chars.removeFirst() }
        if chars.isEmpty || chars == ["."] { return [] }

        func invalid(_ reason: String) -> QueryError {
            QueryError(description: "invalid query '\(query)': \(reason)")
        }

        var segments: [Segment] = []
        var i = 0
        func readKey() throws -> Segment {
            let start = i
            while i < chars.count, chars[i] != ".", chars[i] != "[" { i += 1 }
            guard i > start else { throw invalid("empty key at position \(start)") }
            return .key(String(chars[start..<i]))
        }
        // A bare leading key (`foo.bar`) is accepted because models write it.
        if chars[0] != ".", chars[0] != "[" { segments.append(try readKey()) }

        while i < chars.count {
            if chars[i] == "." {
                i += 1
                // `.[0]` is jq's spelling of `[0]`.
                if i < chars.count, chars[i] == "[" { continue }
                segments.append(try readKey())
                continue
            }
            guard chars[i] == "[" else { throw invalid("expected '.' or '[' at position \(i)") }
            i += 1
            if i < chars.count, chars[i] == "\"" {
                i += 1
                let start = i
                while i < chars.count, chars[i] != "\"" { i += 1 }
                guard i + 1 < chars.count, chars[i + 1] == "]" else { throw invalid("unterminated quoted key") }
                segments.append(.key(String(chars[start..<i])))
                i += 2
                continue
            }
            let start = i
            while i < chars.count, chars[i] != "]" { i += 1 }
            guard i < chars.count else { throw invalid("unterminated '['") }
            let body = String(chars[start..<i])
            i += 1
            if body == "*" {
                segments.append(.wildcard)
            } else if let index = Int(body), index >= 0 {
                segments.append(.index(index))
            } else {
                throw invalid("'[\(body)]' must be a non-negative index, * or a quoted key")
            }
        }
        return segments
    }

    /// Returns the single match, or an array of matches once a `[*]` has been
    /// crossed. Before a `[*]` a miss throws; after one it skips that element.
    static func evaluate(_ segments: [Segment], on root: Any) throws -> Any {
        var matches: [Any] = [root]
        var fannedOut = false
        for segment in segments {
            var next: [Any] = []
            for value in matches {
                switch segment {
                case .key(let key):
                    if let found = (value as? [String: Any])?[key] {
                        next.append(found)
                    } else if !fannedOut {
                        throw QueryError(description: "no key '\(key)' (value is \(typeName(value)))")
                    }
                case .index(let index):
                    if let array = value as? [Any], index < array.count {
                        next.append(array[index])
                    } else if !fannedOut {
                        let detail = (value as? [Any]).map { "array has \($0.count) elements" } ?? "value is \(typeName(value))"
                        throw QueryError(description: "no index \(index) (\(detail))")
                    }
                case .wildcard:
                    if let array = value as? [Any] {
                        next.append(contentsOf: array)
                    } else if !fannedOut {
                        throw QueryError(description: "[*] needs an array (value is \(typeName(value)))")
                    }
                    fannedOut = true
                }
            }
            matches = next
        }
        return fannedOut ? matches : matches[0]
    }

    private static func typeName(_ value: Any) -> String {
        switch value {
        case is [String: Any]: return "an object"
        case is [Any]: return "an array"
        case is NSNull: return "null"
        case is String: return "a string"
        default: return "a number or boolean"
        }
    }

    /// `JSONSerialization` writes 0.1 as 0.10000000000000001, so numbers are
    /// formatted here and only strings go through it.
    private static func serialize(_ value: Any) throws -> String {
        switch value {
        case is NSNull:
            return "null"
        case let string as String:
            let data = try JSONSerialization.data(
                withJSONObject: string,
                options: [.fragmentsAllowed, .withoutEscapingSlashes]
            )
            return String(decoding: data, as: UTF8.self)
        case let array as [Any]:
            return "[" + (try array.map(serialize)).joined(separator: ",") + "]"
        case let object as [String: Any]:
            let fields = try object.keys.sorted().map { key in
                try serialize(key) + ":" + serialize(object[key]!)
            }
            return "{" + fields.joined(separator: ",") + "}"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            if !(number is NSDecimalNumber), number.objCType.pointee == UInt8(ascii: "d") {
                return "\(number.doubleValue)"
            }
            return number.stringValue
        default:
            throw QueryError(description: "value is not JSON")
        }
    }

    static func render(_ value: Any) throws -> String {
        let text = try (value as? String) ?? serialize(value)
        guard text.utf8.count > maxBytes else { return text }
        let head = String(decoding: text.utf8.prefix(maxBytes), as: UTF8.self)
        return head + "\n\n[... truncated at \(maxBytes) bytes; narrow the query ...]"
    }
}
