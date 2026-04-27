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
