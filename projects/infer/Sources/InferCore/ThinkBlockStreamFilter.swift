import Foundation

/// Streaming-safe filter for `<think>…</think>` reasoning blocks
/// emitted by Qwen-3, DeepSeek-R1, and similar reasoning models.
///
/// Feed it `feed(_:)` for each chunk arriving from the runner; it
/// returns text safe to render in the transcript and accumulates the
/// reasoning content into `thinking` separately. Tag boundaries can
/// land mid-chunk (a single piece might be `<thi`), so the filter
/// holds back any tail that might be the start of an open or close
/// tag and waits for more input. `flush()` at end-of-stream emits
/// any genuinely-non-tag tail.
///
/// Supports multiple think blocks in one stream — toggles `inThink`
/// each time it sees a complete `<think>` or `</think>`. Tag matching
/// is case-sensitive (matches what the upstream models emit).
///
/// **Authoritative sentinels (token-ID based).** When the runner
/// recognises the model's special `<think>` / `</think>` token IDs at
/// the vocab level (not a string match against decoded bytes), it can
/// inject a Private-Use Area sentinel character into the stream —
/// `\u{E600}` for open, `\u{E601}` for close. The first sentinel the
/// filter sees flips it into "sentinel mode": from that point on, the
/// surface-form `<think>` / `</think>` strings are treated as ordinary
/// text and never toggle the state. This makes the filter robust
/// against models that mention the literal string `</think>` inside
/// their reasoning (which used to terminate thinking prematurely and
/// leak the rest into the visible reply). Backends that don't emit
/// sentinels (cloud, MLX) keep the legacy string-match path.
public struct ThinkBlockStreamFilter: Sendable {
    /// Captured reasoning text — concatenation of all content seen
    /// while inside `<think>…</think>` blocks. UI shows this in a
    /// collapsible disclosure.
    public private(set) var thinking: String = ""
    /// True when the filter is currently between an open `<think>`
    /// and its matching `</think>`. Pieces fed in this state route
    /// to `thinking`, not to the output. UI can read this to render
    /// a live "thinking…" indicator.
    public private(set) var inThink: Bool = false

    /// Tail of text we've received but haven't classified yet —
    /// might be the leading characters of a `<think>` or `</think>`
    /// tag. Released to either output or `thinking` once we've seen
    /// enough characters to decide.
    private var pending: String = ""

    /// Set once the filter has seen any sentinel from the runner. Once
    /// true, string-matching for `<think>` / `</think>` is disabled —
    /// boundary signals come exclusively from the runner.
    private var sentinelMode: Bool = false

    private static let openTag = "<think>"
    private static let closeTag = "</think>"
    /// Private-Use Area code points the runner injects to mark token-ID-
    /// authoritative boundaries. Chosen from U+E000..U+F8FF where Unicode
    /// guarantees no defined meaning, so a model emitting these by
    /// chance is a non-issue in practice.
    public static let openSentinel = "\u{E600}"
    public static let closeSentinel = "\u{E601}"

    public init() {}

    /// Process the next streamed piece. Returns the text safe to
    /// display now (may be empty if the whole piece was inside a
    /// think block or held as a partial tag). Idempotent under
    /// re-entry — internal state only mutates on each call.
    public mutating func feed(_ piece: String) -> String {
        // Authoritative-sentinel path: if the piece contains either
        // PUA sentinel, the runner is signalling a real boundary —
        // honour it and switch into sentinel mode for the rest of the
        // stream so further surface-form `<think>` / `</think>` tags
        // are treated as literal text.
        if piece.contains(Self.openSentinel) || piece.contains(Self.closeSentinel) {
            return feedWithSentinels(piece)
        }
        if sentinelMode {
            // Already in sentinel mode and no sentinel in this piece —
            // route based purely on `inThink` without scanning for
            // surface-form tags.
            return routePassthrough(piece)
        }

        pending += piece
        var output = ""

        // Loop because a single piece can contain multiple complete
        // tags (rare but possible: a model emitting back-to-back
        // think blocks, or the whole reply in one chunk).
        while !pending.isEmpty {
            let activeTag = inThink ? Self.closeTag : Self.openTag
            if let range = pending.range(of: activeTag) {
                // Found a complete tag. Everything before it is
                // safe — emit to output if outside, capture if
                // inside. Then consume the tag and toggle state.
                let before = String(pending[..<range.lowerBound])
                if inThink { thinking += before } else { output += before }
                pending = String(pending[range.upperBound...])
                inThink.toggle()
                continue
            }
            // No complete tag in pending. Hold back any tail that
            // might be the start of one; release the rest.
            let holdback = Self.partialTagPrefixLength(
                pendingTail: pending,
                tag: activeTag
            )
            if holdback > 0, holdback <= pending.count {
                let cutoff = pending.index(pending.endIndex, offsetBy: -holdback)
                let safe = String(pending[..<cutoff])
                if inThink { thinking += safe } else { output += safe }
                pending = String(pending[cutoff...])
            } else {
                if inThink { thinking += pending } else { output += pending }
                pending = ""
            }
            break
        }
        return output
    }

    /// Walk a piece char-by-char, honouring sentinels as authoritative
    /// boundary signals. Each PUA sentinel toggles `inThink`; non-sentinel
    /// chars route to thinking or output based on the current state.
    /// Drains the legacy `pending` buffer (any partial tag we were
    /// holding back) by appending it to whichever bucket matches the
    /// state in force when this method is entered — `pending` is
    /// inherently a string-match concept and has no place in sentinel
    /// mode beyond that single transition flush.
    private mutating func feedWithSentinels(_ piece: String) -> String {
        var output = ""
        if !pending.isEmpty {
            if inThink { thinking += pending } else { output += pending }
            pending = ""
        }
        sentinelMode = true
        for ch in piece {
            switch String(ch) {
            case Self.openSentinel:
                inThink = true
            case Self.closeSentinel:
                inThink = false
            default:
                if inThink { thinking.append(ch) } else { output.append(ch) }
            }
        }
        return output
    }

    /// Sentinel-mode routing for a piece that doesn't itself contain a
    /// sentinel. Whole piece goes to one bucket based on `inThink` —
    /// no string-match for tags.
    private mutating func routePassthrough(_ piece: String) -> String {
        if inThink {
            thinking += piece
            return ""
        }
        return piece
    }

    /// Stream end — release any held tail. If we're still inside a
    /// think block (model didn't close it), the tail is captured as
    /// thinking; otherwise it goes to output.
    public mutating func flush() -> String {
        let tail = pending
        pending = ""
        if inThink {
            thinking += tail
            return ""
        }
        return tail
    }

    /// How many characters at the end of `pendingTail` could be the
    /// leading characters of `tag`? Returns 0 if no suffix of
    /// `pendingTail` is a prefix of `tag`. Used to decide how much
    /// of the buffer to hold back vs. release.
    ///
    /// Example: pendingTail `"hello </th"`, tag `"</think>"` →
    /// returns 4 (the `</th` could be the start of `</think>`).
    private static func partialTagPrefixLength(
        pendingTail: String,
        tag: String
    ) -> Int {
        let maxCheck = Swift.min(tag.count - 1, pendingTail.count)
        guard maxCheck > 0 else { return 0 }
        for len in stride(from: maxCheck, through: 1, by: -1) {
            let suffix = String(pendingTail.suffix(len))
            if tag.hasPrefix(suffix) { return len }
        }
        return 0
    }
}
