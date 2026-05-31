import SwiftUI
import AppKit
import WebKit
import InferCore

/// Math-delimiter heuristic shared with the print pipeline (`PrintRenderer`
/// calls straight through to this). Display math (`$$`, `\[`) and explicit
/// inline math (`\(`) route unconditionally. Single-`$` inline math also
/// routes, but only for a `$...$` span on one line that (a) does NOT open
/// like a currency amount (`$` immediately followed by digits then a space,
/// e.g. `$5 for`) and (b) contains a LaTeX indicator (`\`, `^`, `_`). This
/// catches model output like `$ \lambda $`, `$x^2$`, AND digit-led math such
/// as `$25^\circ \text{C}$` (the `^` follows the digits with no space, so the
/// currency guard doesn't fire), while rejecting currency prose like
/// "$5 for item_2 and $10" (both `$` open on `digits + space`, so neither is
/// an opener even though an `_` sits between them).
///
/// Known, accepted residual false positives (rare): a span that opens on a
/// non-digit and contains an indicator but is really prose, e.g.
/// "$x_1 costs $5", or a currency amount written with an underscore
/// thousands-separator like "$5_000". Also note this only gates *routing* —
/// a message that legitimately routes AND contains a `$<amount>` span will
/// still feed that span to KaTeX's `$...$` auto-render. These are inherent
/// to supporting single-`$` inline math; the guard targets the common cases.
enum MessageMath {
    /// A `$...$` span (no `$`/newline inside) whose opener isn't a currency
    /// amount (`(?!\d+\s)` rejects `$5 ` but allows `$25^`, `$ \lambda`, `$x`)
    /// and which contains a backslash command, superscript, or subscript —
    /// the indicator class distinguishes inline math from arbitrary
    /// `$…$`-bracketed prose.
    private static let inlineDollarPattern = #"\$(?!\d+\s)[^$\n]*[\\^_][^$\n]*\$"#

    static func containsMath(_ s: String) -> Bool {
        if s.contains("$$") || s.contains("\\(") || s.contains("\\[") {
            return true
        }
        return s.range(of: inlineDollarPattern, options: .regularExpression) != nil
    }
}

/// Renders a single assistant message through WKWebView with full markdown
/// (swift-markdown → HTML), KaTeX, and hljs syntax highlighting, reusing the
/// bundled `WebAssets/` directory the print pipeline already ships. As of the
/// WKWebView-chat-rendering experiment this is the path for *all* assistant
/// messages (math, tables, multi-language code, inline HTML), not just
/// math-bearing ones — unifying live rendering with the PDF/print pipeline.
struct MathMessageView: View {
    let text: String
    /// Cmd+F transcript find state. When non-nil, the WebView's
    /// JS-side highlighter wraps text matches in `<mark>` tags;
    /// `activeMatchIndex` (0-based, message-local) styles the
    /// corresponding match orange instead of yellow. Skips KaTeX-
    /// rendered math nodes and hljs-highlighted code so equations
    /// and code styling don't break.
    var findQuery: String? = nil
    var activeMatchIndex: Int? = nil
    /// Click handler for in-document links. Invoked on the main actor for
    /// every `linkActivated` navigation; the navigation itself is always
    /// cancelled (the handler does the opening — `wiki://` resolves to a
    /// tab, external URLs go to `NSWorkspace`). When nil, links open
    /// externally via `NSWorkspace` (the pre-experiment behaviour).
    var onLinkClick: (@MainActor (URL) -> Void)? = nil
    @State private var height: CGFloat = 20

    var body: some View {
        MathWebView(
            text: text,
            findQuery: findQuery,
            activeMatchIndex: activeMatchIndex,
            onLinkClick: onLinkClick,
            height: $height
        )
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `WKWebView` subclass that forwards vertical scrolling to the enclosing
/// scroll view. A web view embeds its own scroll view that swallows
/// `scrollWheel` events over its content — even when (as for every message
/// here) the view is sized exactly to its content and has nothing to scroll
/// itself. Without this, two-finger scrolling over message *text* does
/// nothing while scrolling over the surrounding margins works, because only
/// the margins let the event reach the transcript's `ScrollView`.
///
/// Vertical-dominant scroll is forwarded to the parent (always safe — the
/// message view has no vertical overflow); horizontal-dominant scroll stays
/// with the web view so wide tables and display math (`overflow-x: auto`)
/// keep their internal horizontal scrolling.
private final class PassthroughScrollWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            if let scrollView = enclosingScrollView {
                scrollView.scrollWheel(with: event)
            } else {
                nextResponder?.scrollWheel(with: event)
            }
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private struct MathWebView: NSViewRepresentable {
    let text: String
    var findQuery: String?
    var activeMatchIndex: Int?
    var onLinkClick: (@MainActor (URL) -> Void)?
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(heightBinding: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "heightChanged")
        config.userContentController = ucc

        let webView = PassthroughScrollWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.pendingText = text
        context.coordinator.onLinkClick = onLinkClick
        webView.loadHTMLString(Self.shellHTML, baseURL: Bundle.main.resourceURL)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onLinkClick = onLinkClick
        context.coordinator.update(text: text)
        context.coordinator.updateFindState(
            query: findQuery,
            activeIndex: activeMatchIndex
        )
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "heightChanged")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onLinkClick: (@MainActor (URL) -> Void)?
        private var hasLoaded = false
        var pendingText: String?
        private var lastSentText: String?
        /// Last find state we pushed into the WebView. Compared
        /// against incoming updates so a no-op SwiftUI re-render
        /// doesn't fire redundant `evaluateJavaScript` calls.
        private var lastFindQuery: String?
        private var lastActiveIndex: Int?
        /// Pending find state captured before the WebView finishes
        /// loading. Applied in `didFinish` alongside `pendingText`.
        private var pendingFindQuery: String?
        private var pendingActiveIndex: Int?
        private let heightBinding: Binding<CGFloat>

        init(heightBinding: Binding<CGFloat>) {
            self.heightBinding = heightBinding
        }

        /// Throttle state. When the `chatThrottleStreaming` setting is
        /// on, rapid streaming updates are coalesced to a fixed cadence
        /// so KaTeX / hljs don't re-run over the whole message on every
        /// token. Leading-edge + trailing-edge: the first update renders
        /// immediately (so a static message scrolled into view isn't
        /// delayed), within-window updates collapse to one trailing
        /// flush, and the final text always lands.
        private var throttlePending: String?
        private var throttleScheduled = false
        private var lastThrottledSend: Date = .distantPast
        private let throttleInterval: TimeInterval = 0.08

        func update(text: String) {
            if !hasLoaded {
                pendingText = text
                return
            }
            if lastSentText == text { return }
            if UserDefaults.standard.bool(forKey: PersistKey.chatThrottleStreaming) {
                scheduleThrottledSend(text: text)
            } else {
                lastSentText = text
                send(text: text)
            }
        }

        private func scheduleThrottledSend(text: String) {
            let now = Date()
            let elapsed = now.timeIntervalSince(lastThrottledSend)
            if elapsed >= throttleInterval && !throttleScheduled {
                lastThrottledSend = now
                lastSentText = text
                send(text: text)
                return
            }
            throttlePending = text
            if throttleScheduled { return }
            throttleScheduled = true
            let delay = max(0, throttleInterval - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.throttleScheduled = false
                guard let t = self.throttlePending else { return }
                self.throttlePending = nil
                if self.lastSentText == t { return }
                self.lastThrottledSend = Date()
                self.lastSentText = t
                self.send(text: t)
            }
        }

        /// Push `findQuery` + active-match-index into the WebView
        /// via a small JS bridge that wraps text matches in
        /// `<mark>` tags. KaTeX-rendered math (`.katex`,
        /// `.katex-display`) and hljs-styled code (`.hljs`) are
        /// skipped during text-node walking so equations and code
        /// rendering aren't disrupted. Self-skips no-op updates.
        func updateFindState(query: String?, activeIndex: Int?) {
            if !hasLoaded {
                pendingFindQuery = query
                pendingActiveIndex = activeIndex
                return
            }
            if lastFindQuery == query && lastActiveIndex == activeIndex {
                return
            }
            lastFindQuery = query
            lastActiveIndex = activeIndex
            applyFindHighlights(query: query, activeIndex: activeIndex)
        }

        private func applyFindHighlights(query: String?, activeIndex: Int?) {
            guard let webView else { return }
            let queryLiteral = jsString(query ?? "")
            let activeLiteral: String
            if let i = activeIndex { activeLiteral = String(i) }
            else { activeLiteral = "-1" }
            let js = "if (typeof applyFindHighlights === 'function') { applyFindHighlights(\(queryLiteral), \(activeLiteral)); }"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        /// JSON-encode a Swift string into a JS string literal —
        /// `"\\n"`, `"\""`, etc. — so we can splice it into an
        /// `evaluateJavaScript` payload safely.
        private func jsString(_ s: String) -> String {
            guard let data = try? JSONSerialization.data(
                withJSONObject: [s], options: .fragmentsAllowed
            ),
                  let str = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            // `[s]` JSON-encoded → "[\"...\"]"; index [0] gets the
            // string literal back.
            return "(\(str))[0]"
        }

        private func send(text: String) {
            guard let webView else { return }
            // Pre-process `[[Page]]` tokens into `[label](wiki://target)`
            // markdown links before HTML conversion, mirroring the old
            // MarkdownUI path's `markdownifyWikilinks` step — so wiki
            // links render and route through `onLinkClick` (the
            // `decidePolicyFor` handler) instead of breaking.
            let html = MathRendering.markdownToHTML(
                MessageWikilinkRenderer.markdownifyWikilinks(text)
            )
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
                    delimiters: \(MathRendering.katexDelimitersJSON),
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
            webView.evaluateJavaScript(js) { [weak self] _, _ in
                // Re-apply find highlights after content + KaTeX +
                // hljs run. Each content swap rebuilds the DOM, so
                // any prior `<mark>` wrappers are gone and need
                // re-application based on the current find state.
                self?.applyFindHighlights(
                    query: self?.lastFindQuery,
                    activeIndex: self?.lastActiveIndex
                )
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            hasLoaded = true
            // Apply pending find state first so the post-send
            // highlight pass picks up the right query/active-index.
            if pendingFindQuery != nil || pendingActiveIndex != nil {
                lastFindQuery = pendingFindQuery
                lastActiveIndex = pendingActiveIndex
                pendingFindQuery = nil
                pendingActiveIndex = nil
            }
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
                // Route through the supplied handler (wiki:// → tab,
                // external → NSWorkspace); fall back to opening
                // externally when no handler is wired. The navigation
                // is always cancelled — the handler does the opening.
                if let onLinkClick {
                    MainActor.assumeIsolated { onLinkClick(url) }
                } else {
                    NSWorkspace.shared.open(url)
                }
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
        /* WebView messages lose SwiftUI's native .textSelection; opt the
           transcript text back into selection (the per-message Copy
           button remains the primary copy affordance). */
        -webkit-user-select: text;
        user-select: text;
      }
      a { cursor: pointer; }
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
      mark.find-match {
        background: yellow;
        color: inherit;
        padding: 0;
        border-radius: 1px;
      }
      mark.find-match.active {
        background: orange;
      }
    </style>
    <script>
    // Cmd+F highlight bridge. The Swift side calls
    // `applyFindHighlights(query, activeIndex)` after each content
    // update + on every find-state change. KaTeX-rendered math
    // (.katex / .katex-display), hljs-styled code (.hljs), <script>,
    // <style>, and any existing <mark> are skipped so equations and
    // code rendering aren't disrupted by text-node mutations.
    function clearFindHighlights() {
      var marks = document.querySelectorAll('mark.find-match');
      marks.forEach(function(mark) {
        var parent = mark.parentNode;
        while (mark.firstChild) {
          parent.insertBefore(mark.firstChild, mark);
        }
        parent.removeChild(mark);
      });
      var content = document.getElementById('content');
      if (content) content.normalize();
    }
    function applyFindHighlights(query, activeIndex) {
      clearFindHighlights();
      if (!query) return;
      var lowerQuery = query.toLowerCase();
      var queryLen = lowerQuery.length;
      if (queryLen === 0) return;
      var content = document.getElementById('content');
      if (!content) return;
      var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
        acceptNode: function(node) {
          var p = node.parentElement;
          while (p && p !== content) {
            if (p.classList && (
              p.classList.contains('katex') ||
              p.classList.contains('katex-display') ||
              p.classList.contains('hljs')
            )) {
              return NodeFilter.FILTER_REJECT;
            }
            var tag = p.tagName;
            if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'MARK') {
              return NodeFilter.FILTER_REJECT;
            }
            p = p.parentElement;
          }
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      var nodes = [];
      var n;
      while ((n = walker.nextNode())) { nodes.push(n); }
      var matchIndex = 0;
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        var text = node.nodeValue;
        var lower = text.toLowerCase();
        var ranges = [];
        var pos = 0;
        while ((pos = lower.indexOf(lowerQuery, pos)) !== -1) {
          ranges.push([pos, pos + queryLen]);
          pos += queryLen;
        }
        if (ranges.length === 0) continue;
        var fragment = document.createDocumentFragment();
        var cursor = 0;
        for (var r = 0; r < ranges.length; r++) {
          var start = ranges[r][0];
          var end = ranges[r][1];
          if (start > cursor) {
            fragment.appendChild(document.createTextNode(text.slice(cursor, start)));
          }
          var mark = document.createElement('mark');
          mark.className = 'find-match' + (matchIndex === activeIndex ? ' active' : '');
          mark.textContent = text.slice(start, end);
          fragment.appendChild(mark);
          cursor = end;
          matchIndex += 1;
        }
        if (cursor < text.length) {
          fragment.appendChild(document.createTextNode(text.slice(cursor)));
        }
        node.parentNode.replaceChild(fragment, node);
      }
    }
    </script>
    </head>
    <body><div id="content"></div></body>
    </html>
    """#
}
