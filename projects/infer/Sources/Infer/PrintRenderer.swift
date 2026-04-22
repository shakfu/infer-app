import AppKit
import WebKit
import PDFKit
import Markdown

@MainActor
enum PrintRenderer {
    /// Retain per-operation WKWebView + delegate until the async PDF/print
    /// flow finishes. Keyed by an object identity so multiple operations
    /// (e.g. print + export) don't stomp on each other.
    private static var pending: [ObjectIdentifier: Holder] = [:]

    // MARK: - Public entry points

    static func printTranscript(_ messages: [ChatMessage]) {
        renderPDF(for: messages) { result in
            switch result {
            case .success(let data):
                guard let pdf = PDFDocument(data: data) else {
                    NSLog("PrintRenderer: PDFDocument init failed")
                    return
                }
                let info = NSPrintInfo.shared
                info.topMargin = pageSideMargin
                info.bottomMargin = pageSideMargin
                info.leftMargin = pageSideMargin
                info.rightMargin = pageSideMargin
                info.horizontalPagination = .automatic
                info.verticalPagination = .automatic
                guard let op = pdf.printOperation(
                    for: info,
                    scalingMode: .pageScaleNone,
                    autoRotate: true
                ) else {
                    NSLog("PrintRenderer: PDFDocument.printOperation returned nil")
                    return
                }
                op.jobTitle = "Infer transcript"
                op.run()
            case .failure(let err):
                NSLog("PrintRenderer: createPDF failed: \(err)")
            }
        }
    }

    /// Write a rendered HTML copy of the transcript to `url`. References
    /// are relative to a `WebAssets/` directory (bundled KaTeX +
    /// highlight.js) — so opened standalone, code blocks fall back to plain
    /// `<pre>` styling and math stays as raw `$…$` delimiters. For a fully
    /// self-contained artifact with rendered math/highlighting, use Export
    /// as PDF instead; that pipeline snapshots the WebView after KaTeX and
    /// hljs run against the bundled assets.
    static func exportHTML(_ messages: [ChatMessage], to url: URL) throws {
        let html = transcriptHTML(messages)
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Render the transcript through WKWebView and write the resulting PDF.
    /// `WKWebView.createPDF` produces a single tall page; we slice it into
    /// paper-sized pages via Core Graphics before writing to disk.
    /// Async under the hood; invokes `completion` on the main actor.
    static func exportPDF(
        _ messages: [ChatMessage],
        to url: URL,
        completion: @MainActor @escaping (Result<Void, Error>) -> Void
    ) {
        renderPDF(for: messages) { result in
            switch result {
            case .success(let tallData):
                guard let paginated = paginate(tallData) else {
                    completion(.failure(renderError("Pagination failed")))
                    return
                }
                do {
                    try paginated.write(to: url, options: .atomic)
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    /// Split a single tall PDF page into multiple paper-sized pages.
    /// Uses `NSPrintInfo.shared.paperSize` so users in Letter or A4 locales
    /// get the expected page size. Horizontally centers the source content
    /// within each page (source width is already ≈ paperWidth − 2*margin,
    /// so this is usually a no-op or a tiny offset).
    private static func paginate(_ srcData: Data) -> Data? {
        guard let srcDoc = PDFDocument(data: srcData),
              let srcPage = srcDoc.page(at: 0)
        else { return nil }
        let srcBounds = srcPage.bounds(for: .mediaBox)

        let pageSize = NSPrintInfo.shared.paperSize
        let margin = pageSideMargin
        let sliceHeight = pageSize.height - 2 * margin
        guard sliceHeight > 0 else { return nil }

        let numPages = max(1, Int(ceil(srcBounds.height / sliceHeight)))
        let xOffset = max(margin, (pageSize.width - srcBounds.width) / 2)

        let outData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: outData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }

        for i in 0..<numPages {
            // Translate the source so that slice `i` aligns inside the
            // dst page's content rect. PDF coords are bottom-left origin.
            // The top of slice `i` in src is at y = srcH − i*sliceH; we want
            // that to land at y = pageH − margin in dst.
            let dy = CGFloat(i) * sliceHeight - srcBounds.height
                     + pageSize.height - margin
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // Clip so a tall slice doesn't bleed into the margins.
            ctx.clip(to: CGRect(
                x: margin,
                y: margin,
                width: pageSize.width - 2 * margin,
                height: sliceHeight
            ))
            ctx.translateBy(x: xOffset, y: dy)
            srcPage.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return outData as Data
    }

    private static func renderError(_ msg: String) -> NSError {
        NSError(domain: "PrintRenderer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }

    // MARK: - HTML generation

    /// Heuristic: does the rendered body contain LaTeX math delimiters KaTeX
    /// should render? Inline `$...$` is intentionally excluded to avoid
    /// false positives on prose like "$5 and $10" — users can switch to
    /// `\(...\)` for inline math.
    private static func containsMath(_ body: String) -> Bool {
        body.contains("$$") || body.contains("\\(") || body.contains("\\[")
    }

    /// Full wrapped HTML for the transcript. Exposed so export-as-HTML and
    /// the print pipeline share one source of truth for styling.
    static func transcriptHTML(_ messages: [ChatMessage]) -> String {
        let markdown = messages
            .map { "## \($0.role.rawValue)\n\n\($0.text)" }
            .joined(separator: "\n\n---\n\n")
        let document = Document(parsing: markdown.isEmpty ? "_(empty transcript)_" : markdown)
        let bodyHTML = HTMLFormatter.format(document)
        return wrap(body: bodyHTML)
    }

    private static func wrap(body: String) -> String {
        let wantMath = containsMath(body)
        let mathHead = wantMath
            ? #"<link rel="stylesheet" href="WebAssets/katex/katex.min.css">"#
            : ""
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>Infer transcript</title>
          <link rel="stylesheet" href="WebAssets/highlight/github.min.css">
          <script src="WebAssets/highlight/highlight.min.js"></script>
          \(mathHead)
          <style>
            body { font: 13px -apple-system, system-ui, sans-serif; color: #111; margin: 0; }
            h1 { font-size: 20px; border-bottom: 1px solid #ccc; padding-bottom: 4px; margin: 24px 0 12px; }
            h2 { font-size: 16px; color: #555; margin: 20px 0 10px; }
            h3 { font-size: 14px; color: #666; margin: 16px 0 8px; }
            p { line-height: 1.5; margin: 8px 0; }
            code { font-family: Menlo, ui-monospace, monospace; font-size: 12px; background: #f5f5f5; padding: 1px 4px; border-radius: 3px; }
            pre { background: #f5f5f5; padding: 10px; border-radius: 4px; font: 12px Menlo, ui-monospace, monospace; line-height: 1.45; white-space: pre-wrap; word-wrap: break-word; overflow-wrap: anywhere; }
            pre code { background: transparent; padding: 0; white-space: inherit; word-wrap: inherit; overflow-wrap: inherit; }
            /* highlight.js overrides: let its theme stylesheet set the colors,
               but keep our pre container styling. */
            pre code.hljs { background: transparent; padding: 0; }
            hr { border: 0; border-top: 1px solid #ddd; margin: 20px 0; }
            blockquote { border-left: 3px solid #ccc; padding-left: 10px; color: #555; margin: 10px 0; }
            ul, ol { padding-left: 22px; line-height: 1.5; }
            table { border-collapse: collapse; margin: 12px 0; width: 100%; font-size: 12px; }
            th, td { border: 1px solid #dcdcdc; padding: 6px 10px; text-align: left; vertical-align: top; }
            th { background: #f0f0f0; font-weight: 600; color: #333; }
            tbody tr:nth-child(odd) { background: #fafafa; }
            tbody tr:nth-child(even) { background: #ffffff; }
            caption { font-size: 12px; color: #666; padding: 4px 0 6px; caption-side: top; text-align: left; font-style: italic; }
            a { color: #0366d6; text-decoration: none; }
          </style>
        </head>
        <body>
        \(body)
        <script>
          // Both hljs and KaTeX are loaded from the bundled WebAssets/ dir
          // via parser-blocking <script src> tags above; by the time this
          // inline script runs they're available. WKWebView's didFinish
          // waits for this synchronous path, so createPDF snapshots a
          // fully-rendered page.
          if (typeof hljs !== 'undefined') {
            try { hljs.highlightAll(); } catch (e) { console.warn('hljs failed:', e); }
          }
        </script>
        \(wantMath ? mathScripts : "")
        </body>
        </html>
        """
    }

    /// KaTeX auto-render scripts. Emitted only when the transcript contains
    /// math delimiters. Loaded parser-blocking (no `defer`) and placed at
    /// end-of-body so the call to `renderMathInElement` fires synchronously
    /// before WKWebView's `didFinish`, keeping the PDF snapshot flow
    /// straightforward. Code blocks (`<pre>`, `<code>`) are skipped by
    /// KaTeX's default `ignoredTags` so fenced code with `$` characters
    /// isn't mis-rendered.
    private static let mathScripts = #"""
        <script src="WebAssets/katex/katex.min.js"></script>
        <script src="WebAssets/katex/contrib/auto-render.min.js"></script>
        <script>
          if (typeof renderMathInElement !== 'undefined') {
            try {
              renderMathInElement(document.body, {
                delimiters: [
                  {left: '$$', right: '$$', display: true},
                  {left: '\\[', right: '\\]', display: true},
                  {left: '\\(', right: '\\)', display: false}
                ],
                throwOnError: false
              });
            } catch (e) { console.warn('KaTeX failed:', e); }
          }
        </script>
        """#

    // MARK: - Shared WKWebView → PDF pipeline

    /// Side margin in points applied to both WebView layout width and the
    /// print operation. 36pt = 0.5 inch, matching the previous print code.
    private static let pageSideMargin: CGFloat = 36

    private static func renderPDF(
        for messages: [ChatMessage],
        completion: @MainActor @escaping (Result<Data, Error>) -> Void
    ) {
        let html = transcriptHTML(messages)

        // Compute the layout width from the paper size directly. Reading
        // `NSPrintInfo.shared.leftMargin` here would pick up the OS default
        // (~72pt) rather than the 36pt we actually use for the print op,
        // producing a narrower PDF than expected.
        let paperWidth = NSPrintInfo.shared.paperSize.width
        let printableWidth = paperWidth - 2 * pageSideMargin

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: printableWidth, height: 800)
        )
        let host = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.contentView = webView
        host.orderOut(nil)

        let holder = Holder(webView: webView, host: host, completion: completion)
        pending[ObjectIdentifier(holder)] = holder
        webView.navigationDelegate = holder
        // `baseURL` is the app's Resources/ dir so the HTML's relative
        // `WebAssets/...` references resolve to the bundled KaTeX /
        // highlight.js files. `loadFileURL` would be needed for true
        // `file://` reads, but `loadHTMLString` with a file baseURL works
        // for <link>/<script src> in WKWebView.
        let base = Bundle.main.resourceURL
        webView.loadHTMLString(html, baseURL: base)
    }

    // MARK: - Holder

    private final class Holder: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        let host: NSWindow
        let completion: @MainActor (Result<Data, Error>) -> Void

        init(
            webView: WKWebView,
            host: NSWindow,
            completion: @escaping @MainActor (Result<Data, Error>) -> Void
        ) {
            self.webView = webView
            self.host = host
            self.completion = completion
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            let config = WKPDFConfiguration()
            config.rect = nil
            webView.createPDF(configuration: config) { [self] result in
                Task { @MainActor in
                    defer { PrintRenderer.pending.removeValue(forKey: ObjectIdentifier(self)) }
                    switch result {
                    case .success(let data):
                        completion(.success(data))
                    case .failure(let err):
                        completion(.failure(err))
                    }
                }
            }
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            NSLog("PrintRenderer: load failed: \(error)")
            Task { @MainActor in
                PrintRenderer.pending.removeValue(forKey: ObjectIdentifier(self))
                completion(.failure(error))
            }
        }
    }
}
