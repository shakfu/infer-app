import Foundation

/// Output of `TextSplitter.split(_:)` — one chunk of the source with
/// byte-accurate offsets into the original string. `offsetStart` and
/// `offsetEnd` are grapheme-cluster counts from the start of the
/// original text; they're suitable for "chunk at position N" UI but
/// not for random-access indexing into UTF-8 bytes (convert through
/// `String.Index` if that's needed).
public struct TextChunk: Equatable, Sendable {
    public let content: String
    public let offsetStart: Int
    public let offsetEnd: Int

    public init(content: String, offsetStart: Int, offsetEnd: Int) {
        self.content = content
        self.offsetStart = offsetStart
        self.offsetEnd = offsetEnd
    }
}

/// Hierarchical recursive character splitter. Ported from the cyllama
/// Python implementation's `TextSplitter`, which in turn is the
/// familiar LangChain-shaped recursive splitter.
///
/// Algorithm:
///   1. If the whole text is ≤ `chunkSize`, return it as one chunk.
///   2. Otherwise, try separators in order of preference
///      (double-newline → single-newline → sentence → word → char).
///      For the first separator that appears, split the text into
///      pieces, then recursively re-split any piece that's still too
///      large using the remaining separators.
///   3. When no separator reduces a piece, hard-split at the
///      character (grapheme) boundary.
///   4. Merge the resulting pieces back together greedily up to
///      `chunkSize`, seeding each new chunk with the tail of the
///      previous chunk for `chunkOverlap` characters so context
///      straddles chunk boundaries.
///
/// Size and offset arithmetic uses grapheme-cluster counts, not byte
/// counts — consistent with Swift's native `String.count`. The offsets
/// are meaningful to the UI ("chunk at grapheme N of the source") but
/// shouldn't be treated as byte positions.
public struct TextSplitter: Sendable {
    public let chunkSize: Int
    public let chunkOverlap: Int
    public let separators: [String]

    public static let defaultSeparators: [String] = ["\n\n", "\n", ". ", " ", ""]

    public init(
        chunkSize: Int = 512,
        chunkOverlap: Int = 50,
        separators: [String] = TextSplitter.defaultSeparators
    ) {
        precondition(chunkSize > 0, "chunkSize must be > 0")
        precondition(chunkOverlap >= 0, "chunkOverlap must be >= 0")
        precondition(chunkOverlap < chunkSize, "chunkOverlap must be < chunkSize")
        self.chunkSize = chunkSize
        self.chunkOverlap = chunkOverlap
        self.separators = separators
    }

    /// Split `text` into chunks. Returns an empty array for
    /// whitespace-only input (there's nothing to embed).
    public func split(_ text: String) -> [TextChunk] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let pieces = recursiveSplit(text: text, offset: 0, separators: separators)
        return merge(pieces)
    }

    // MARK: - Internals

    /// A substring of the original text carrying its starting offset.
    /// Internal to the splitter; callers only see `TextChunk`.
    private struct Piece {
        let content: String
        let offset: Int
        var size: Int { content.count }
    }

    private func recursiveSplit(
        text: String,
        offset: Int,
        separators: [String]
    ) -> [Piece] {
        if text.count <= chunkSize {
            return text.isEmpty ? [] : [Piece(content: text, offset: offset)]
        }

        // Find the first separator that actually occurs in `text`, or
        // the terminal empty-string separator which always "matches"
        // and triggers the character-level hard split.
        var chosenIndex = separators.count - 1
        for (i, sep) in separators.enumerated() {
            if sep.isEmpty { chosenIndex = i; break }
            if text.range(of: sep) != nil { chosenIndex = i; break }
        }
        let chosen = separators[chosenIndex]
        let nextSeparators = Array(separators.dropFirst(chosenIndex + 1))

        let firstSplit: [Piece]
        if chosen.isEmpty {
            firstSplit = hardSplit(text: text, offset: offset)
        } else {
            firstSplit = splitKeepingSeparator(
                text: text,
                separator: chosen,
                offset: offset
            )
        }

        // Recursively split any piece that's still oversized.
        var out: [Piece] = []
        for piece in firstSplit {
            if piece.size <= chunkSize {
                out.append(piece)
            } else if nextSeparators.isEmpty {
                out.append(contentsOf: hardSplit(
                    text: piece.content,
                    offset: piece.offset
                ))
            } else {
                out.append(contentsOf: recursiveSplit(
                    text: piece.content,
                    offset: piece.offset,
                    separators: nextSeparators
                ))
            }
        }
        return out
    }

    /// Split `text` by `separator`, attaching each separator
    /// occurrence to the *preceding* piece so that concatenating all
    /// pieces yields the original text (no characters lost). Empty
    /// pieces (from trailing separators or doubled separators) are
    /// dropped.
    private func splitKeepingSeparator(
        text: String,
        separator: String,
        offset: Int
    ) -> [Piece] {
        var pieces: [Piece] = []
        var remaining = Substring(text)
        var cursor = 0
        while !remaining.isEmpty {
            if let range = remaining.range(of: separator) {
                let pieceEnd = range.upperBound
                let content = String(remaining[remaining.startIndex..<pieceEnd])
                if !content.isEmpty {
                    pieces.append(Piece(content: content, offset: offset + cursor))
                    cursor += content.count
                }
                remaining = remaining[pieceEnd...]
            } else {
                let content = String(remaining)
                if !content.isEmpty {
                    pieces.append(Piece(content: content, offset: offset + cursor))
                }
                break
            }
        }
        return pieces
    }

    /// Hard-split at grapheme boundaries when no separator fits.
    /// Produces pieces of exactly `chunkSize` except possibly the
    /// last, which is whatever remains.
    private func hardSplit(text: String, offset: Int) -> [Piece] {
        var pieces: [Piece] = []
        var cursor = text.startIndex
        var localOffset = 0
        while cursor < text.endIndex {
            let end = text.index(
                cursor,
                offsetBy: chunkSize,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            let content = String(text[cursor..<end])
            pieces.append(Piece(content: content, offset: offset + localOffset))
            localOffset += content.count
            cursor = end
        }
        return pieces
    }

    /// Greedy merge: accumulate pieces into the current chunk until
    /// adding the next piece would exceed `chunkSize`, then flush.
    /// On flush, the tail of the flushed chunk (up to `chunkOverlap`
    /// characters) seeds the next chunk so the next embedding sees
    /// the end of the previous one.
    ///
    /// This diverges slightly from LangChain's per-piece overlap —
    /// we use *character* overlap rather than *piece* overlap, so
    /// the overlap size is predictable regardless of how fragmented
    /// the recursive split produced.
    private func merge(_ pieces: [Piece]) -> [TextChunk] {
        var chunks: [TextChunk] = []
        var current: [Piece] = []
        var currentSize = 0

        func flush() {
            guard !current.isEmpty else { return }
            let content = current.map(\.content).joined()
            let start = current.first!.offset
            let end = start + content.count
            chunks.append(TextChunk(
                content: content,
                offsetStart: start,
                offsetEnd: end
            ))
            // Seed next chunk with the tail of this one as overlap.
            if chunkOverlap > 0 {
                let overlapLen = min(chunkOverlap, content.count)
                if overlapLen > 0 {
                    let tailContent = String(content.suffix(overlapLen))
                    current = [Piece(
                        content: tailContent,
                        offset: end - overlapLen
                    )]
                    currentSize = overlapLen
                    return
                }
            }
            current = []
            currentSize = 0
        }

        for piece in pieces {
            if currentSize + piece.size > chunkSize, !current.isEmpty {
                flush()
            }
            current.append(piece)
            currentSize += piece.size
        }
        flush()
        return chunks
    }
}
