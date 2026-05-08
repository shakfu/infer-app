import Foundation
import AppKit
import SwiftTreeSitter
import TreeSitterPython

/// Highlights a snippet of Python source via tree-sitter-python +
/// the upstream `highlights.scm` query. Returns a list of `(NSRange,
/// NSColor)` tuples for the caller to apply onto an `NSTextStorage`
/// at an absolute base offset.
///
/// The query is loaded once at init from a file the
/// `tree-sitter-python` fetcher staged into the Infer target's
/// resource bundle. Capture names follow nvim-treesitter conventions
/// (`@function`, `@keyword`, `@string.escape`, etc.); we map the
/// common ones to NSColors below. Unknown captures fall through to
/// the surrounding base color.
final class WikiPythonHighlighter {
    private let parser: Parser
    private let language: Language
    private let highlightsQuery: Query?
    /// Cache the most recently parsed Python snippet so successive
    /// calls on the same source skip the parse + query work. The
    /// fenced-code content of a single `python` block typically gets
    /// re-highlighted on every keystroke in the surrounding doc;
    /// caching by source string is a cheap win without needing
    /// incremental edit tracking inside the snippet.
    private var cacheKey: String = ""
    private var cacheResult: [(range: NSRange, color: NSColor)] = []

    init() {
        let lang = Language(language: tree_sitter_python())
        self.language = lang
        let p = Parser()
        try? p.setLanguage(lang)
        self.parser = p

        // Resource staged by `scripts/manage.py:fetch_tree_sitter_python`.
        if let url = Bundle.module.url(forResource: "python_highlights", withExtension: "scm"),
           let data = try? Data(contentsOf: url) {
            self.highlightsQuery = try? Query(language: lang, data: data)
        } else {
            self.highlightsQuery = nil
        }
    }

    /// Run the highlights query against `source` and return absolute-
    /// offset color spans. `baseOffset` is the location of `source`
    /// inside the host document (the storage where colors will be
    /// applied), in NSString / UTF-16 units.
    func highlights(for source: String, baseOffset: Int) -> [(range: NSRange, color: NSColor)] {
        if source == cacheKey {
            return cacheResult.map { hit in
                (range: NSRange(location: baseOffset + hit.range.location, length: hit.range.length),
                 color: hit.color)
            }
        }
        guard let highlightsQuery, let tree = parser.parse(source) else {
            return []
        }
        let cursor = highlightsQuery.execute(in: tree)
        let context = Predicate.Context(string: source)
        // Track which (range, capture) pairs we've already emitted so
        // overlapping query patterns (e.g. `(identifier) @variable`
        // catches everything; later more-specific captures like
        // `@function` should win) don't double-paint. Tree-sitter
        // emits matches in document order; later overrides earlier.
        var output: [(range: NSRange, color: NSColor)] = []
        var occupied: [NSRange] = []
        while let match = cursor.nextMatch() {
            guard match.allowed(in: context) else { continue }
            for capture in match.captures {
                guard let name = capture.name,
                      let color = Self.color(forCapture: name) else { continue }
                let local = capture.range
                // Drop any prior less-specific spans this capture
                // overlaps. Captures are emitted most-general first
                // (`identifier`) then more-specific (`function`); the
                // more-specific should win.
                output.removeAll { existing in
                    NSIntersectionRange(existing.range, local).length > 0
                        && existing.range.length > 0
                        && existing.range.location >= local.location
                        && existing.range.location + existing.range.length
                            <= local.location + local.length
                }
                occupied.append(local)
                output.append((range: local, color: color))
            }
        }
        cacheKey = source
        cacheResult = output
        return output.map { hit in
            (range: NSRange(location: baseOffset + hit.range.location, length: hit.range.length),
             color: hit.color)
        }
    }

    /// Map nvim-treesitter capture names → on-screen colors. Hierarchy
    /// match: try the full name, then progressively shorter dotted
    /// prefixes (`function.method` → `function.method` → `function`).
    /// Returns nil for capture names we don't style; the caller leaves
    /// the underlying base text color in place.
    static func color(forCapture name: String) -> NSColor? {
        var key = name
        while !key.isEmpty {
            if let c = palette[key] { return c }
            // Walk up dotted hierarchy.
            if let dot = key.lastIndex(of: ".") {
                key = String(key[..<dot])
            } else {
                return nil
            }
        }
        return nil
    }

    /// Capture-name → color palette. Drawn from a Sundell-ish Swift
    /// theme (matches the chat's prior Splash colors roughly) so the
    /// wiki editor's Python and the chat's Swift feel like the same
    /// visual family. Adjust freely; the entries are independent.
    private static let palette: [String: NSColor] = [
        "keyword":           NSColor.systemPurple,
        "operator":          NSColor.secondaryLabelColor,
        "punctuation":       NSColor.secondaryLabelColor,
        "punctuation.special": NSColor.systemPurple,
        "string":            NSColor.systemRed,
        "string.escape":     NSColor.systemOrange,
        "escape":            NSColor.systemOrange,
        "number":            NSColor.systemTeal,
        "comment":           NSColor.secondaryLabelColor,
        "function":          NSColor.systemBlue,
        "function.builtin":  NSColor.systemTeal,
        "function.method":   NSColor.systemBlue,
        "type":              NSColor.systemTeal,
        "constructor":       NSColor.systemTeal,
        "constant":          NSColor.systemOrange,
        "constant.builtin":  NSColor.systemPurple,
        "property":          NSColor.systemBrown,
        "embedded":          NSColor.textColor,
        // `@variable` is everywhere; leaving it out keeps the base
        // text color intact, which reads better than recoloring every
        // identifier.
    ]
}
