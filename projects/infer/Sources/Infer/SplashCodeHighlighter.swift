import SwiftUI
import MarkdownUI
import Splash

struct SplashCodeHighlighter: CodeSyntaxHighlighter {
    private let syntaxHighlighter: SyntaxHighlighter<TextOutputFormat>

    init(theme: Splash.Theme) {
        self.syntaxHighlighter = SyntaxHighlighter(format: TextOutputFormat(theme: theme))
    }

    func highlightCode(_ content: String, language: String?) -> Text {
        // Splash only knows Swift. Fall back to plain monospaced text for
        // other languages so code still renders readably.
        guard (language ?? "").lowercased() == "swift" else {
            return Text(content).font(.system(.body, design: .monospaced))
        }
        return syntaxHighlighter.highlight(content)
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
