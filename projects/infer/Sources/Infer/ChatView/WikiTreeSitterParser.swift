import Foundation
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline

/// Block-level markdown parser backed by tree-sitter-qmd. Returns the
/// minimal structural data the wiki editor's styling pass needs:
///
/// - heading position, level, and marker range
/// - fenced code block outer range, inner content range, language tag
///
/// We deliberately don't surface the full AST — the inline grammar is
/// not used (would need a second parser instance), and other block
/// types (lists, blockquotes, tables) aren't styled differently from
/// regular text in the current design. Add cases here as the styling
/// pass grows.
///
/// The block grammar's quirk: headings always include a trailing
/// newline character in their range. We keep that in `outerRange` so
/// callers can apply line-level attributes (heading font) without
/// post-processing — adding a heading font to the newline is a no-op
/// visually but lets `addAttributes` apply uniformly.
struct ParsedBlock {
    enum Kind {
        case heading(level: Int)
        /// Language tag from the info string, lowercased + trimmed.
        /// `nil` when the fence has no info string (`” + ``` `).
        case fencedCode(language: String?)
    }

    let kind: Kind
    /// The full construct: heading line (incl. markers + inline) or
    /// the entire fenced block (delimiters + content).
    let outerRange: NSRange
    /// Heading: the inline-content range (heading text minus marker).
    /// Fenced code: the content between delimiters, excluding the
    /// delimiter lines. Empty for a fence with no body.
    let innerRange: NSRange?
    /// Heading: the `#` markers (and the single mandatory space).
    /// Fenced code: the info string range (lang tag), if present.
    let markerRange: NSRange?
}

/// Inline-level construct produced by the second-stage parse with
/// `tree-sitter-markdown-inline`. The wiki-styling pass converts each
/// span into NSAttributedString attributes (bold / italic / monospaced
/// + dimmed background / accent + underline).
struct ParsedInlineSpan {
    enum Kind {
        case emphasis             // `*text*` / `_text_` → italic
        case strongEmphasis       // `**text**` → bold
        case codeSpan             // `` `text` `` → monospaced
        case inlineLink           // `[text](url)` → accent + underline
    }
    let kind: Kind
    let range: NSRange
}

/// Aggregate result of one parse. The styling pass consumes both
/// halves: blocks for layout (heading fonts, fenced code, list /
/// blockquote markers); inlines for character-level emphasis.
struct ParsedDocument {
    let blocks: [ParsedBlock]
    let inlines: [ParsedInlineSpan]
}

final class WikiTreeSitterParser {
    private let parser: Parser            // block grammar
    private let inlineParser: Parser      // inline grammar
    /// Most recently parsed tree, kept alive so the next parse can
    /// reuse subtrees that haven't been touched. Reset to nil on
    /// errors / first call.
    private var cachedTree: MutableTree?
    private var cachedInlineTree: MutableTree?
    /// Snapshot of the source text that produced `cachedTree`. The
    /// next parse compares against this to derive the `InputEdit`
    /// without needing an out-of-band edit-event hook from the text
    /// view. UTF-16 unit comparison is fast (effectively memcmp on
    /// the underlying buffers) and makes the integration agnostic to
    /// what kind of editor the document came from.
    private var cachedUTF16: [UInt16] = []

    init() {
        let p = Parser()
        try? p.setLanguage(Language(language: tree_sitter_markdown()))
        self.parser = p

        // Inline parser: parses emphasis / code spans / inline links
        // out of the same source text. Used as a second stage; the
        // styling pass filters its output to spans that fall inside
        // `inline` block-nodes, so e.g. `**bold**` written inside a
        // fenced code block doesn't get bolded.
        let ip = Parser()
        try? ip.setLanguage(Language(language: tree_sitter_markdown_inline()))
        self.inlineParser = ip
    }

    /// Parse `text` and return the block-level constructs we care
    /// about, in document order.
    ///
    /// Incremental: when a cached tree is present, the parser is fed
    /// an `InputEdit` derived from a UTF-16 diff between the cached
    /// source and `text`, plus the prior tree. Tree-sitter then reuses
    /// any subtree whose range was not invalidated by the edit. For a
    /// single-character keystroke in a multi-page document this drops
    /// the parse from O(N) work to O(log N) on average.
    ///
    /// Falls back to a full reparse when there is no cached tree, or
    /// when the diff would span the entire document (rare; happens
    /// only on programmatic full-text replacement).
    func parse(text: String) -> ParsedDocument {
        let newUTF16 = Array(text.utf16)
        let edit = (cachedTree != nil && !cachedUTF16.isEmpty)
            ? computeEdit(old: cachedUTF16, new: newUTF16)
            : nil
        let tree: MutableTree?
        let inlineTree: MutableTree?
        if let edit, let prev = cachedTree {
            prev.edit(edit)
            tree = parser.parse(tree: prev, string: text)
        } else {
            tree = parser.parse(text)
        }
        if let edit, let prev = cachedInlineTree {
            prev.edit(edit)
            inlineTree = inlineParser.parse(tree: prev, string: text)
        } else {
            inlineTree = inlineParser.parse(text)
        }
        cachedTree = tree
        cachedInlineTree = inlineTree
        cachedUTF16 = newUTF16

        let nsText = text as NSString
        var blocks: [ParsedBlock] = []
        var inlineRanges: [NSRange] = []
        if let tree, let root = tree.rootNode {
            walk(node: root, text: nsText, blocks: &blocks, inlineRanges: &inlineRanges)
        }
        var inlines: [ParsedInlineSpan] = []
        if let inlineTree, let root = inlineTree.rootNode {
            walkInline(node: root, into: &inlines)
        }
        // Filter inline spans to those fully contained in some
        // `inline` block-node range. Without this, the inline parser's
        // hits inside fenced code blocks (e.g. `**args` in Python)
        // would produce bogus emphasis attributes.
        inlines = inlines.filter { span in
            inlineRanges.contains { Self.contains(outer: $0, inner: span.range) }
        }
        return ParsedDocument(blocks: blocks, inlines: inlines)
    }

    private static func contains(outer: NSRange, inner: NSRange) -> Bool {
        inner.location >= outer.location &&
            inner.location + inner.length <= outer.location + outer.length
    }

    /// Compute the byte-level extent of an edit between two UTF-16
    /// buffers by trimming common prefixes and suffixes. Returns nil
    /// when the buffers are identical.
    ///
    /// The `Point` fields on `InputEdit` are zeroed — tree-sitter's
    /// docs say row/column values are optional when the host code
    /// doesn't itself use line-relative positioning, and we don't
    /// (the styling pass works in NSRange / UTF-16 offsets).
    private func computeEdit(old: [UInt16], new: [UInt16]) -> InputEdit? {
        if old.count == new.count {
            // Fast path: same length, find first/last differing index.
            var same = true
            for i in 0..<old.count where old[i] != new[i] { same = false; break }
            if same { return nil }
        }
        var start = 0
        let minLen = Swift.min(old.count, new.count)
        while start < minLen && old[start] == new[start] { start += 1 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start && newEnd > start && old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        // Tree-sitter uses byte offsets. With native UTF-16 encoding
        // (the default Parser uses), each code unit is 2 bytes.
        return InputEdit(
            startByte: start * 2,
            oldEndByte: oldEnd * 2,
            newEndByte: newEnd * 2,
            startPoint: .zero,
            oldEndPoint: .zero,
            newEndPoint: .zero
        )
    }

    /// Drop the cached tree. Call when the underlying document is
    /// programmatically replaced (e.g. switching between wiki pages)
    /// so the next parse doesn't try to incrementally apply a diff
    /// that's actually a complete swap.
    func resetCache() {
        cachedTree = nil
        cachedUTF16 = []
    }

    private func walk(
        node: Node,
        text: NSString,
        blocks: inout [ParsedBlock],
        inlineRanges: inout [NSRange]
    ) {
        switch node.nodeType {
        case "atx_heading":
            if let block = makeHeading(node: node) {
                blocks.append(block)
                if let inner = block.innerRange { inlineRanges.append(inner) }
            }
            return
        case "setext_heading":
            if let block = makeSetextHeading(node: node) {
                blocks.append(block)
                if let inner = block.innerRange { inlineRanges.append(inner) }
            }
            return
        case "fenced_code_block", "pandoc_code_block":
            // Both share the same child layout (delimiter / info_string |
            // attribute_specifier / code_fence_content / delimiter).
            // The pandoc form additionally accepts `{lang}` style
            // attribute specifiers; `makeFence` extracts the language
            // from either shape.
            if let block = makeFence(node: node, text: text) {
                blocks.append(block)
            }
            return
        case "inline":
            // Block grammar's leaf for inline-content text. Record the
            // range so the inline-grammar pass can be filtered to
            // matter only inside these regions.
            inlineRanges.append(node.range)
            return
        default:
            break
        }
        for i in 0..<node.childCount {
            if let child = node.child(at: i) {
                walk(node: child, text: text, blocks: &blocks, inlineRanges: &inlineRanges)
            }
        }
    }

    /// Walk the inline-grammar tree, emitting one `ParsedInlineSpan`
    /// per recognized span (emphasis / strong / code_span / inline_link).
    /// Spans don't nest meaningfully for our styling purposes so we
    /// keep the walk shallow — emphasis-inside-emphasis would still
    /// produce two spans, both of which apply via attribute layering.
    private func walkInline(node: Node, into spans: inout [ParsedInlineSpan]) {
        if let kind = Self.inlineKind(for: node.nodeType) {
            spans.append(ParsedInlineSpan(kind: kind, range: node.range))
        }
        for i in 0..<node.childCount {
            if let child = node.child(at: i) {
                walkInline(node: child, into: &spans)
            }
        }
    }

    private static func inlineKind(for type: String?) -> ParsedInlineSpan.Kind? {
        switch type {
        case "emphasis": return .emphasis
        case "strong_emphasis": return .strongEmphasis
        case "code_span": return .codeSpan
        case "inline_link": return .inlineLink
        default: return nil
        }
    }

    private func makeHeading(node: Node) -> ParsedBlock? {
        // atx_heading children: atx_h*_marker, inline (optional).
        var level = 1
        var markerRange: NSRange?
        var innerRange: NSRange?
        for i in 0..<node.childCount {
            guard let child = node.child(at: i),
                  let type = child.nodeType else { continue }
            if type.hasPrefix("atx_h"), type.hasSuffix("_marker") {
                let digit = type.dropFirst(5).first.flatMap { Int(String($0)) }
                level = digit ?? 1
                markerRange = child.range
            } else if type == "inline" {
                innerRange = child.range
            }
        }
        return ParsedBlock(
            kind: .heading(level: level),
            outerRange: node.range,
            innerRange: innerRange,
            markerRange: markerRange
        )
    }

    private func makeSetextHeading(node: Node) -> ParsedBlock? {
        // Setext: paragraph (text) + underline. Level: 1 for `===`, 2 for `---`.
        var level = 1
        var innerRange: NSRange?
        for i in 0..<node.childCount {
            guard let child = node.child(at: i),
                  let type = child.nodeType else { continue }
            switch type {
            case "setext_h1_underline": level = 1
            case "setext_h2_underline": level = 2
            case "paragraph":
                // The visible heading text. Its `inline` child will be
                // captured separately by the generic walker recursing
                // into setext nodes.
                innerRange = child.range
            default: break
            }
        }
        return ParsedBlock(
            kind: .heading(level: level),
            outerRange: node.range,
            innerRange: innerRange,
            markerRange: nil
        )
    }

    private func makeFence(node: Node, text: NSString) -> ParsedBlock? {
        // Children of fenced_code_block / pandoc_code_block:
        //   fenced_code_block_delimiter (open)
        //   info_string  | attribute_specifier  (either form, or none)
        //   code_fence_content?
        //   fenced_code_block_delimiter (close)
        var infoRange: NSRange?
        var contentRange: NSRange?
        var language: String?
        for i in 0..<node.childCount {
            guard let child = node.child(at: i),
                  let type = child.nodeType else { continue }
            switch type {
            case "info_string":
                infoRange = child.range
                let raw = text.substring(with: child.range)
                language = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            case "attribute_specifier":
                // Pandoc-style `{python}` / `{r, echo=FALSE}`. Dim the
                // whole curly-braced block; pull the language tag from
                // the `language_specifier` child (always the first
                // recognized identifier inside the braces).
                infoRange = child.range
                language = Self.languageFromAttributeSpecifier(child, text: text)
            case "code_fence_content":
                contentRange = child.range
            default:
                break
            }
        }
        return ParsedBlock(
            kind: .fencedCode(language: language),
            outerRange: node.range,
            innerRange: contentRange,
            markerRange: infoRange
        )
    }

    private static func languageFromAttributeSpecifier(
        _ node: Node, text: NSString
    ) -> String? {
        // Recursively look for a `language_specifier` descendant —
        // the grammar allows nested braces (e.g. `{{r}}`), so a flat
        // child scan misses the deeper case.
        var found: String?
        func recurse(_ n: Node) {
            if found != nil { return }
            if n.nodeType == "language_specifier" {
                let raw = text.substring(with: n.range)
                found = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return
            }
            for i in 0..<n.childCount {
                if let c = n.child(at: i) { recurse(c) }
            }
        }
        recurse(node)
        return found
    }
}
