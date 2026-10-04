import Foundation

/// Heading outline of a document, used to label RAG chunks with the
/// section they came from (`Plan > 3.1 Schema`).
///
/// Markdown ATX headings (`## Title`) outside fenced code define the
/// outline. Text with no ATX headings falls back to short `Chapter N` /
/// `Part N` / `Book N` lines, the common markers in plain-text books.
/// Offsets are grapheme-cluster counts, matching `TextChunk`.
public struct SectionOutline: Sendable {
    public struct Heading: Equatable, Sendable {
        public let offset: Int
        /// Titles from the outermost heading down to this one.
        public let path: [String]
    }

    public let headings: [Heading]

    /// Path separator in the rendered label.
    public static let separator = " > "
    /// Labels longer than this are clipped from the front, keeping the
    /// innermost headings.
    static let maxLabelLength = 200

    public init(_ text: String) {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var atx: [(offset: Int, level: Int, title: String)] = []
        var chapters: [(offset: Int, level: Int, title: String)] = []
        var offset = 0
        var fence: Character?
        for line in lines {
            let trimmed = line.drop { $0 == " " }
            if let marker = trimmed.first, marker == "`" || marker == "~",
               trimmed.prefix(3).allSatisfy({ $0 == marker }), trimmed.count >= 3 {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
            } else if fence == nil {
                if let h = Self.atxHeading(line) {
                    atx.append((offset, h.level, h.title))
                } else if let h = Self.chapterHeading(line) {
                    chapters.append((offset, h.level, h.title))
                }
            }
            offset += line.count + 1
        }

        var stack: [(level: Int, title: String)] = []
        var out: [Heading] = []
        for h in atx.isEmpty ? chapters : atx {
            while let last = stack.last, last.level >= h.level { stack.removeLast() }
            stack.append((h.level, h.title))
            out.append(Heading(offset: h.offset, path: stack.map(\.title)))
        }
        headings = out
    }

    /// Label of the section in effect at `offset`, or nil before the
    /// first heading.
    public func label(at offset: Int) -> String? {
        guard let h = headings.last(where: { $0.offset <= offset }) else { return nil }
        let label = h.path.joined(separator: Self.separator)
        guard label.count > Self.maxLabelLength else { return label }
        return "…" + label.suffix(Self.maxLabelLength - 1)
    }

    /// Label for a chunk. Uses the first character after the overlap
    /// prefix, so a chunk that opens with the previous section's tail
    /// and then a heading is labelled with the new heading.
    public func label(for chunk: TextChunk, overlap: Int) -> String? {
        let probe = Swift.min(chunk.offsetStart + overlap, Swift.max(chunk.offsetStart, chunk.offsetEnd - 1))
        return label(at: probe)
    }

    static func atxHeading(_ line: Substring) -> (level: Int, title: String)? {
        let leading = line.prefix { $0 == " " }.count
        guard leading <= 3 else { return nil }
        let rest = line.dropFirst(leading)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let afterHashes = rest.dropFirst(level)
        guard let first = afterHashes.first, first == " " || first == "\t" else { return nil }
        var title = afterHashes.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: `## Title ##`.
        while title.hasSuffix("#") { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (level, title)
    }

    private static let chapterKeywords: [String: Int] = [
        "book": 1, "part": 1, "chapter": 2,
    ]
    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
    ]

    /// `Chapter 3`, `PART IV`, `Book One: The Return`. The second token
    /// must be a number, roman numeral, or number word, so prose such
    /// as "Part of the problem" is not a heading.
    static func chapterHeading(_ line: Substring) -> (level: Int, title: String)? {
        let title = line.trimmingCharacters(in: .whitespaces)
        guard title.count <= 80 else { return nil }
        let tokens = title.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 2,
              let level = chapterKeywords[tokens[0].lowercased()]
        else { return nil }
        let number = tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
        let isNumber = !number.isEmpty && (
            number.allSatisfy(\.isNumber)
            || number.allSatisfy({ "IVXLCDM".contains($0) })
            || numberWords.contains(number.lowercased())
        )
        return isNumber ? (level, title) : nil
    }
}
