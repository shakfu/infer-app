import Foundation
import Markdown

/// Single source of truth for turning assistant markdown that contains LaTeX
/// into KaTeX-ready HTML. Shared by the on-screen `MathMessageView` and the
/// `PrintRenderer` export/print path so both agree on (a) which delimiters
/// KaTeX's `auto-render` recognizes and (b) the pre-parse stashing that keeps
/// swift-markdown from eating LaTeX backslashes. Detection (whether a message
/// routes here at all) lives separately in `MessageMath`.
enum MathRendering {
    /// KaTeX `auto-render` delimiter list, as a JS array literal spliced
    /// verbatim into both render scripts. `$$` precedes `$` so display math is
    /// matched before inline. Defined as a raw string so the embedded `\\[` /
    /// `\\(` reach the JS source as the literal `\[` / `\(` KaTeX expects.
    /// In-app interpolates with `\(...)` (non-raw string); the print path uses
    /// `\#(...)` (raw string) — both insert this value unchanged.
    static let katexDelimitersJSON = #"""
    [
      {left: '$$', right: '$$', display: true},
      {left: '\\[', right: '\\]', display: true},
      {left: '\\(', right: '\\)', display: false},
      {left: '$', right: '$', display: false}
    ]
    """#

    /// Render markdown to HTML while protecting LaTeX delimiters. swift-markdown
    /// treats `\(`, `\[`, and `\\` as backslash escapes and strips them, which
    /// would destroy the delimiters KaTeX needs. Stash them in placeholder
    /// tokens before parsing, then restore them in the rendered HTML. KaTeX runs
    /// against the restored delimiters afterward in the WebView.
    static func markdownToHTML(_ text: String) -> String {
        let stashed = text
            .replacingOccurrences(of: "\\\\", with: "\u{0001}MATHBSL\u{0001}")
            .replacingOccurrences(of: "\\(", with: "\u{0001}MATHIL\u{0001}")
            .replacingOccurrences(of: "\\)", with: "\u{0001}MATHIR\u{0001}")
            .replacingOccurrences(of: "\\[", with: "\u{0001}MATHDL\u{0001}")
            .replacingOccurrences(of: "\\]", with: "\u{0001}MATHDR\u{0001}")
        let doc = Document(parsing: stashed)
        var html = HTMLFormatter.format(doc)
        html = html
            .replacingOccurrences(of: "\u{0001}MATHIL\u{0001}", with: "\\(")
            .replacingOccurrences(of: "\u{0001}MATHIR\u{0001}", with: "\\)")
            .replacingOccurrences(of: "\u{0001}MATHDL\u{0001}", with: "\\[")
            .replacingOccurrences(of: "\u{0001}MATHDR\u{0001}", with: "\\]")
            .replacingOccurrences(of: "\u{0001}MATHBSL\u{0001}", with: "\\\\")
        return html
    }
}
