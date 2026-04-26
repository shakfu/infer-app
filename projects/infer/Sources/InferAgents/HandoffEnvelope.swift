import Foundation

/// Sentinel-based handoff envelope for inter-agent communication.
///
/// `agent_composition.md` open question 1 (resolved 2026-04-26): for v1
/// composition, an agent that wants to delegate to a peer emits a free-
/// text envelope wrapped in `<<HANDOFF target="…">>` … `<<END_HANDOFF>>`
/// inside its assistant text. The composition driver strips the envelope
/// from the user-visible body and passes the inner payload to the named
/// peer as that agent's user turn. Future schemas may swap the sentinel
/// for a structured tool-call shape; the parser is isolated here so the
/// migration is local.
public enum HandoffEnvelope {
    /// Result of scanning assistant text for a handoff envelope.
    public struct Parsed: Equatable, Sendable {
        /// User-visible body — the assistant's reply with the envelope
        /// stripped. May be empty if the agent emitted only an envelope.
        public let visibleText: String
        /// Handoff payload, or nil if no envelope was present.
        public let handoff: Handoff?

        public init(visibleText: String, handoff: Handoff?) {
            self.visibleText = visibleText
            self.handoff = handoff
        }
    }

    public struct Handoff: Equatable, Sendable {
        public let target: AgentID
        /// Free-text payload between the open and close sentinels.
        /// Trimmed of surrounding whitespace; otherwise unstructured.
        public let payload: String

        public init(target: AgentID, payload: String) {
            self.target = target
            self.payload = payload
        }
    }

    /// Scan `text` for the first `<<HANDOFF target="…">>` … `<<END_HANDOFF>>`
    /// pair. Returns the visible body (envelope stripped) and the parsed
    /// handoff, or `(text, nil)` if no envelope is present.
    ///
    /// Tolerant parser: a malformed open sentinel (missing `target`,
    /// missing close) returns the original text with no handoff —
    /// surface-and-show beats swallow-and-lose for unexpected output.
    /// Only the first complete envelope matters; later ones in the
    /// same text stay verbatim in `visibleText`.
    public static func parse(_ text: String) -> Parsed {
        guard let openRange = text.range(of: "<<HANDOFF") else {
            return Parsed(visibleText: text, handoff: nil)
        }
        // Find the close of the open sentinel: ">>".
        let afterOpen = text[openRange.upperBound...]
        guard let openCloseRange = afterOpen.range(of: ">>") else {
            return Parsed(visibleText: text, handoff: nil)
        }
        let attrs = afterOpen[..<openCloseRange.lowerBound]
        guard let target = parseTargetAttribute(attrs), !target.isEmpty else {
            return Parsed(visibleText: text, handoff: nil)
        }

        // Now look for the close sentinel after the open's `>>`.
        let bodyStart = openCloseRange.upperBound
        let afterOpenSentinel = text[bodyStart...]
        guard let closeRange = afterOpenSentinel.range(of: "<<END_HANDOFF>>") else {
            // Unterminated envelope — keep as visible text rather than
            // dropping the model's output.
            return Parsed(visibleText: text, handoff: nil)
        }

        let payload = afterOpenSentinel[..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Stitch visible text: prefix + suffix-after-close-sentinel.
        let prefix = text[..<openRange.lowerBound]
        let suffix = afterOpenSentinel[closeRange.upperBound...]
        let visible = (String(prefix) + String(suffix))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Parsed(
            visibleText: visible,
            handoff: Handoff(target: target, payload: payload)
        )
    }

    /// Extract `target="…"` from the attribute string between
    /// `<<HANDOFF` and `>>`. Accepts either double or single quotes.
    /// Returns nil when the attribute is absent or unbalanced.
    private static func parseTargetAttribute(_ attrs: Substring) -> AgentID? {
        let trimmed = attrs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eq = trimmed.range(of: "target=") else { return nil }
        let afterEq = trimmed[eq.upperBound...]
        guard let firstChar = afterEq.first else { return nil }
        let quote: Character
        if firstChar == "\"" || firstChar == "'" {
            quote = firstChar
        } else {
            return nil
        }
        let afterQuote = afterEq.dropFirst()
        guard let closeQuote = afterQuote.firstIndex(of: quote) else { return nil }
        return AgentID(String(afterQuote[..<closeQuote]))
    }
}
