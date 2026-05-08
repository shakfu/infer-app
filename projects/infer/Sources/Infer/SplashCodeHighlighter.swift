import SwiftUI
import AppKit
import MarkdownUI
import Splash
import Highlightr

/// Markdown code-fence highlighter. Swift goes through `Splash`
/// (Sundell's Swift-specific tokenizer — produces nicer Swift output
/// than highlight.js's generic grammar). Everything else routes to
/// `Highlightr`, a JavaScriptCore wrapper around highlight.js with
/// ~190 grammars built in. Unknown / unspecified languages fall back
/// to plain monospaced text.
struct SplashCodeHighlighter: CodeSyntaxHighlighter {
    private let syntaxHighlighter: SyntaxHighlighter<TextOutputFormat>
    /// Highlightr is expensive to construct (boots a JSContext and
    /// loads highlight.js + the active stylesheet), so we cache one
    /// instance per highlighter. Concurrent use from the SwiftUI render
    /// path appears to be safe — highlight.js is purely functional and
    /// JSContext is reentrant for our usage pattern (single render thread).
    private let highlightr: Highlightr?
    private let highlightrTheme: String

    /// `theme` styles Swift via Splash. `highlightrTheme` is a
    /// highlight.js theme name (e.g. `"xcode"`, `"github"`,
    /// `"atom-one-dark"`) for everything else; defaults to `"xcode"`
    /// to roughly match Splash's Sundell colors in light mode.
    init(theme: Splash.Theme, highlightrTheme: String = "xcode") {
        self.syntaxHighlighter = SyntaxHighlighter(format: TextOutputFormat(theme: theme))
        let hl = Highlightr()
        hl?.setTheme(to: highlightrTheme)
        self.highlightr = hl
        self.highlightrTheme = highlightrTheme
    }

    func highlightCode(_ content: String, language: String?) -> Text {
        let lang = (language ?? "").lowercased()
        if lang == "swift" {
            return syntaxHighlighter.highlight(content)
        }
        // No language tag — render plain monospaced. highlight.js's
        // auto-detection is unreliable for short snippets and tends
        // to mis-color shell prompts as random languages.
        guard !lang.isEmpty,
              let highlightr,
              let attributed = highlightr.highlight(content, as: lang, fastRender: true)
        else {
            return Text(content).font(.system(.body, design: .monospaced))
        }
        return attributedToText(attributed)
    }

    /// Convert a highlight.js-produced `NSAttributedString` into a
    /// SwiftUI `Text` by concatenating per-run colored `Text` spans.
    /// We deliberately ignore the font from Highlightr's NSAttributed
    /// output (it ships a system serif at a fixed size); apply our
    /// own monospaced body font so the chat transcript stays
    /// visually consistent across languages.
    private func attributedToText(_ attributed: NSAttributedString) -> Text {
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

extension CodeSyntaxHighlighter where Self == SplashCodeHighlighter {
    static func splash(theme: Splash.Theme) -> Self {
        SplashCodeHighlighter(theme: theme)
    }
}

/// Splash OutputFormat that emits SwiftUI Text with foreground colors per token type.
private struct TextOutputFormat: OutputFormat {
    let theme: Splash.Theme

    func makeBuilder() -> Builder { Builder(theme: theme) }

    struct Builder: OutputBuilder {
        let theme: Splash.Theme
        private var accumulatedText: [Text] = []

        init(theme: Splash.Theme) { self.theme = theme }

        mutating func addToken(_ token: String, ofType type: TokenType) {
            let color = theme.tokenColors[type] ?? theme.plainTextColor
            accumulatedText.append(
                Text(token)
                    .foregroundColor(Color(color))
                    .font(.system(.body, design: .monospaced))
            )
        }

        mutating func addPlainText(_ text: String) {
            accumulatedText.append(
                Text(text)
                    .foregroundColor(Color(theme.plainTextColor))
                    .font(.system(.body, design: .monospaced))
            )
        }

        mutating func addWhitespace(_ whitespace: String) {
            accumulatedText.append(
                Text(whitespace).font(.system(.body, design: .monospaced))
            )
        }

        func build() -> Text {
            accumulatedText.reduce(Text(""), +)
        }
    }
}
