import Foundation

/// Strip everything that looks like an HTML tag from `s`. Not a real
/// parser — `NSRegularExpression` against `<[^>]+>`. Tolerant of
/// untrusted input: the regex is anchored to ASCII and won't match
/// across Unicode emoji or accented characters that happen to contain
/// `<` / `>`.
///
/// Used by tools that consume a search-engine HTML snippet (DDG)
/// or a Wikipedia search snippet (which highlights matches with
/// `<span class="searchmatch">` markup) and want plain text to hand
/// to the model.
public func stripHTMLTags(_ s: String) -> String {
    s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
}

/// Tiny HTML entity decoder. Covers the entities search-engine
/// snippets typically emit — `&amp;`, `&quot;`, `&#39;` / `&#x27;`,
/// `&lt;`, `&gt;`, `&nbsp;`. A full decoder would need
/// `NSAttributedString(html:)` or a third-party HTML parser, both
/// heavier than this seven-entity table warrants.
///
/// Replacement order matters: `&amp;` must come last so an entity
/// like `&amp;quot;` doesn't decode to `&quot;` and then to `"` —
/// but in practice DDG / MediaWiki double-encode rarely enough that
/// the simpler order below is fine. If a real double-encoded source
/// shows up later, swap to a single regex pass keyed on `&...;`
/// matches.
public func decodeHTMLEntities(_ s: String) -> String {
    var out = s
    let table: [(String, String)] = [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&#x27;", "'"),
        ("&nbsp;", " "),
    ]
    for (entity, replacement) in table {
        out = out.replacingOccurrences(of: entity, with: replacement)
    }
    return out
}

/// Reduces an HTML page to readable text: the `<main>` or `<article>` content
/// when the page marks one, otherwise the body without its header and footer.
/// Uses regexes over a parser because no HTML5 parser is available here, so a
/// nested `<nav>` can leave a fragment behind.
public func htmlToPlainText(_ html: String) -> String {
    let page = html.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
    for tag in ["main", "article"] {
        if let range = page.range(of: "(?is)<\(tag)\\b[^>]*>.*</\(tag)\\s*>", options: .regularExpression) {
            let text = plainText(String(page[range]), dropping: [])
            if !text.isEmpty { return text }
        }
    }
    return plainText(page, dropping: ["header", "footer"])
}

private func plainText(_ html: String, dropping extraElements: [String]) -> String {
    let dropped = ["script", "style", "head", "noscript", "template", "svg", "nav", "aside", "form", "button", "select"] + extraElements
    var text = html.replacingOccurrences(
        of: "(?is)<(\(dropped.joined(separator: "|")))\\b.*?</\\1\\s*>",
        with: "",
        options: .regularExpression
    )
    text = text.replacingOccurrences(
        of: "(?i)</?(p|div|br|hr|li|ul|ol|tr|table|h[1-6]|section|article|header|footer|main|blockquote|pre)\\b[^>]*>",
        with: "\n",
        options: .regularExpression
    )
    text = decodeHTMLEntities(stripHTMLTags(text))
    text = text.replacingOccurrences(of: "[ \\t\u{00A0}]+", with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?m)^ | $", with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}
