import Foundation

/// Parse / render Infer's canonical Save-Transcript markdown format. Lives
/// in InferCore so it can be unit-tested without the Infer target's UI
/// dependencies. Emits role-string + text tuples; the caller maps to its
/// own `ChatMessage` type.
public enum TranscriptMarkdown {
    public struct Turn: Equatable, Sendable {
        public let role: String
        public let text: String
        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// Serialize turns into the canonical markdown format. Each turn is a
    /// `## <role>` header followed by a blank line and the content; turns
    /// are separated by `\n\n---\n\n`.
    public static func render(_ turns: [Turn]) -> String {
        turns
            .map { "## \($0.role)\n\n\($0.text)" }
            .joined(separator: "\n\n---\n\n")
    }

    /// Parse a canonical transcript back into turns. Strict enough to
    /// round-trip `render`; lenient about extra whitespace and unknown
    /// roles (skipped). Returns an empty array when no recognizable turns
    /// are found.
    public static func parse(_ markdown: String) -> [Turn] {
        var result: [Turn] = []
        let chunks = markdown.components(separatedBy: "\n\n---\n\n")
        for raw in chunks {
            let chunk = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard chunk.hasPrefix("## ") else { continue }
            guard let bodyBreak = chunk.range(of: "\n\n") else { continue }
            let headerStart = chunk.index(chunk.startIndex, offsetBy: 3)
            let header = chunk[headerStart..<bodyBreak.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let body = String(chunk[bodyBreak.upperBound...])
            switch header {
            case "user", "assistant", "system":
                result.append(Turn(role: header, text: body))
            default:
                continue
            }
        }
        return result
    }
}
