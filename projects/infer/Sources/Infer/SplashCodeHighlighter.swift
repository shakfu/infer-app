import SwiftUI
import AppKit
import MarkdownUI
import Highlightr

/// Markdown code-fence highlighter for the chat transcript. Wraps
/// `Highlightr` (highlight.js via JavaScriptCore) for arbitrary-
/// language fenced blocks. Unknown / unspecified languages render in
/// plain monospaced — highlight.js's auto-detection mis-colors short
/// snippets, so we don't enable it.
///
/// File still named `SplashCodeHighlighter.swift` for git-history
/// continuity; the previous implementation routed Swift through
/// Splash. Splash was dropped because Highlightr handles Swift
/// adequately and we wanted a single coloring path. The wiki editor
/// uses tree-sitter instead and does not link this type.
struct ChatCodeHighlighter: CodeSyntaxHighlighter {
    /// Highlightr is expensive to construct (boots a JSContext + loads
    /// highlight.js + the active stylesheet), so we cache one instance
    /// per highlighter. Concurrent use from the SwiftUI render path
    /// appears safe — highlight.js is purely functional and JSContext
    /// is reentrant for our usage pattern (single render thread).
    private let highlightr: Highlightr?

    /// `theme` is a highlight.js theme name (e.g. `"xcode"`,
    /// `"github"`, `"atom-one-dark"`). Defaults to `"xcode"` to match
    /// macOS's system aesthetic.
    init(theme: String = "xcode") {
        let hl = Highlightr()
        hl?.setTheme(to: theme)
        self.highlightr = hl
    }

    func highlightCode(_ content: String, language: String?) -> Text {
        let lang = (language ?? "").lowercased()
        guard !lang.isEmpty,
              let highlightr,
              let attributed = highlightr.highlight(content, as: lang, fastRender: true)
        else {
            return Text(content).font(.system(.body, design: .monospaced))
        }
        return Self.attributedToText(attributed)
    }

    /// Convert a highlight.js-produced `NSAttributedString` into a
    /// SwiftUI `Text` by concatenating per-run colored spans. Font
    /// from Highlightr's output is dropped in favor of our monospaced
    /// body font for visual consistency across the transcript.
    private static func attributedToText(_ attributed: NSAttributedString) -> Text {
        var result = Text("")
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            let substring = (attributed.string as NSString).substring(with: range)
            var span = Text(substring).font(.system(.body, design: .monospaced))
            if let color = value as? NSColor {
                span = span.foregroundColor(Color(color))
            }
            result = result + span
        }
        return result
    }
}

extension CodeSyntaxHighlighter where Self == ChatCodeHighlighter {
    static func chat(theme: String = "xcode") -> Self {
        ChatCodeHighlighter(theme: theme)
    }
}
