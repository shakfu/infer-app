import SwiftUI
import AppKit
import WebKit
import Markdown

/// Math-delimiter heuristic shared with `PrintRenderer.containsMath`. Inline
/// `$...$` is intentionally excluded to avoid false positives on prose like
/// "$5 and $10".
enum MessageMath {
    static func containsMath(_ s: String) -> Bool {
        s.contains("$$") || s.contains("\\(") || s.contains("\\[")
    }
}

/// Renders a single assistant message through WKWebView with KaTeX + hljs,
/// reusing the bundled `WebAssets/` directory the print pipeline already
/// ships. Used only when the message text contains math delimiters; non-math
/// assistant messages stay on the SwiftUI/MarkdownUI path.
struct MathMessageView: View {
    let text: String
    @State private var height: CGFloat = 20

    var body: some View {
        MathWebView(text: text, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MathWebView: NSViewRepresentable {
    let text: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(heightBinding: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "heightChanged")
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.pendingText = text
        webView.loadHTMLString(Self.shellHTML, baseURL: Bundle.main.resourceURL)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.update(text: text)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "heightChanged")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var hasLoaded = false
        var pendingText: String?
        private var lastSentText: String?
        private let heightBinding: Binding<CGFloat>

        init(heightBinding: Binding<CGFloat>) {
            self.heightBinding = heightBinding
        }

        func update(text: String) {
            if !hasLoaded {
                pendingText = text
                return
            }
            if lastSentText == text { return }
            lastSentText = text
            send(text: text)
        }

        private func send(text: String) {
            guard let webView else { return }
            let html = Self.markdownToHTML(text)
            guard let payload = try? JSONSerialization.data(
                withJSONObject: [html],
                options: [.fragmentsAllowed]
            ),
                  let json = String(data: payload, encoding: .utf8) else { return }
            // `json` is a JSON array containing the HTML string; index [0]
            // gives us a properly-escaped JS string literal.
            let js = """
            (function(){
              var c = document.getElementById('content');
              if (!c) return;
              c.innerHTML = (\(json))[0];
              if (typeof renderMathInElement !== 'undefined') {
                try {
                  renderMathInElement(c, {
                    delimiters: [
                      {left: '$$', right: '$$', display: true},
                      {left: '\\\\[', right: '\\\\]', display: true},
                      {left: '\\\\(', right: '\\\\)', display: false}
                    ],
                    throwOnError: false
                  });
                } catch (e) {}
              }
              if (typeof hljs !== 'undefined') {
                try {
                  c.querySelectorAll('pre code').forEach(function(b){
                    hljs.highlightElement(b);
                  });
                } catch (e) {}
              }
              var h = Math.ceil(document.body.getBoundingClientRect().height);
              window.webkit.messageHandlers.heightChanged.postMessage(h);
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        private static func markdownToHTML(_ text: String) -> String {
            // swift-markdown will eat `\(`, `\[` and `\\` in raw text — KaTeX
            // needs those delimiters intact. Stash them in placeholder tokens
            // before parsing, then restore in the rendered HTML.
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

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            hasLoaded = true
            if let t = pendingText {
                pendingText = nil
                lastSentText = nil
                send(text: t)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "heightChanged" else { return }
            let value: CGFloat
            if let n = message.body as? CGFloat { value = n }
            else if let n = message.body as? Double { value = CGFloat(n) }
            else if let n = message.body as? Int { value = CGFloat(n) }
            else { return }
            DispatchQueue.main.async { [heightBinding] in
                let clamped = max(20, value)
                if abs(heightBinding.wrappedValue - clamped) > 0.5 {
                    heightBinding.wrappedValue = clamped
                }
            }
        }
    }

    /// Static HTML shell loaded once per WebView. The transcript content is
    /// pushed in via `evaluateJavaScript` so streaming token updates don't
    /// reload the document. References are relative to `Bundle.main`'s
    /// `WebAssets/` directory, mirroring `PrintRenderer.wrap`.
    private static let shellHTML: String = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <link rel="stylesheet" href="WebAssets/highlight/github.min.css">
    <script src="WebAssets/highlight/highlight.min.js"></script>
    <link rel="stylesheet" href="WebAssets/katex/katex.min.css">
    <script src="WebAssets/katex/katex.min.js"></script>
    <script src="WebAssets/katex/contrib/auto-render.min.js"></script>
    <style>
      :root {
        color-scheme: light dark;
        --fg: #111;
        --muted: #555;
        --border: #ddd;
        --code-bg: #f5f5f5;
        --link: #0366d6;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --fg: #e6e6e6;
          --muted: #b0b0b0;
          --border: #3a3a3a;
          --code-bg: #1f1f1f;
          --link: #4ea3ff;
        }
      }
      html, body { background: transparent; margin: 0; padding: 0; }
      body {
        font: 13px -apple-system, system-ui, sans-serif;
        color: var(--fg);
        line-height: 1.5;
      }
      #content > *:first-child { margin-top: 0; }
      #content > *:last-child { margin-bottom: 0; }
      h1 { font-size: 20px; border-bottom: 1px solid var(--border); padding-bottom: 4px; margin: 18px 0 10px; }
      h2 { font-size: 16px; color: var(--muted); margin: 16px 0 8px; }
      h3 { font-size: 14px; color: var(--muted); margin: 14px 0 6px; }
      p { margin: 6px 0; }
      code { font-family: Menlo, ui-monospace, monospace; font-size: 12px; background: var(--code-bg); padding: 1px 4px; border-radius: 3px; }
      pre { background: var(--code-bg); padding: 10px; border-radius: 4px; font: 12px Menlo, ui-monospace, monospace; line-height: 1.45; white-space: pre-wrap; word-wrap: break-word; overflow-wrap: anywhere; }
      pre code { background: transparent; padding: 0; white-space: inherit; }
      pre code.hljs { background: transparent; padding: 0; }
      hr { border: 0; border-top: 1px solid var(--border); margin: 16px 0; }
      blockquote { border-left: 3px solid var(--border); padding-left: 10px; color: var(--muted); margin: 10px 0; }
      ul, ol { padding-left: 22px; }
      table { border-collapse: collapse; margin: 10px 0; width: 100%; font-size: 12px; }
      th, td { border: 1px solid var(--border); padding: 6px 10px; text-align: left; vertical-align: top; }
      a { color: var(--link); text-decoration: none; }
      .katex-display { margin: 8px 0; overflow-x: auto; overflow-y: hidden; }
    </style>
    </head>
    <body><div id="content"></div></body>
    </html>
    """#
}
