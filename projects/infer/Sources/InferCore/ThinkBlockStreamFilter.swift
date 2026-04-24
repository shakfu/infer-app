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

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    public init() {}

    /// Process the next streamed piece. Returns the text safe to
    /// display now (may be empty if the whole piece was inside a
    /// think block or held as a partial tag). Idempotent under
    /// re-entry — internal state only mutates on each call.
    public mutating func feed(_ piece: String) -> String {
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
