import AppKit
import WebKit
import PDFKit
import Markdown

@MainActor
enum PrintRenderer {
    /// Retain the WKWebView + delegate across the async load; cleared once the
    /// print operation finishes.
    private static var pending: Holder?

    static func printTranscript(_ messages: [ChatMessage]) {
        let markdown = messages
            .map { "## \($0.role.rawValue)\n\n\($0.text)" }
            .joined(separator: "\n\n---\n\n")
        let document = Document(parsing: markdown.isEmpty ? "_(empty transcript)_" : markdown)
        let bodyHTML = HTMLFormatter.format(document)
        let html = wrap(body: bodyHTML)

        let info = NSPrintInfo.shared
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic

        // Give the webView the printable width so CSS layout uses it; height
        // is a starting hint only — createPDF(configuration:) captures the
        // full content height regardless of frame.
        let printableWidth = info.paperSize.width - info.leftMargin - info.rightMargin
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: printableWidth, height: 800)
        )

        // WKWebView's print pipeline is more reliable when the view is hosted
        // in a window, even if that window is off-screen.
        let host = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.contentView = webView
        host.orderOut(nil)

        let holder = Holder(webView: webView, host: host, info: info)
        pending = holder
        webView.navigationDelegate = holder
        webView.loadHTMLString(html, baseURL: nil)
    }

    private static func wrap(body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            body { font: 13px -apple-system, system-ui, sans-serif; color: #111; margin: 0; }
            h1 { font-size: 20px; border-bottom: 1px solid #ccc; padding-bottom: 4px; margin: 24px 0 12px; }
            h2 { font-size: 16px; color: #555; margin: 20px 0 10px; }
            h3 { font-size: 14px; color: #666; margin: 16px 0 8px; }
            p { line-height: 1.5; margin: 8px 0; }
            code { font-family: Menlo, ui-monospace, monospace; font-size: 12px; background: #f5f5f5; padding: 1px 4px; border-radius: 3px; }
            pre { background: #f5f5f5; padding: 10px; border-radius: 4px; overflow-x: auto; font: 12px Menlo, ui-monospace, monospace; line-height: 1.45; }
            pre code { background: transparent; padding: 0; }
            hr { border: 0; border-top: 1px solid #ddd; margin: 20px 0; }
            blockquote { border-left: 3px solid #ccc; padding-left: 10px; color: #555; margin: 10px 0; }
            ul, ol { padding-left: 22px; line-height: 1.5; }
            table { border-collapse: collapse; margin: 10px 0; }
            th, td { border: 1px solid #ddd; padding: 4px 8px; }
            a { color: #0366d6; text-decoration: none; }
          </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private final class Holder: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        let host: NSWindow
        let info: NSPrintInfo

        init(webView: WKWebView, host: NSWindow, info: NSPrintInfo) {
            self.webView = webView
            self.host = host
            self.info = info
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            // WKWebView.printOperation(with:) produces blank pages when the
            // view isn't attached to a key window. Route through PDFKit
            // instead: render HTML → PDF data → PDFDocument → print op.
            // rect = nil → WebKit captures the entire content (not just the
            // visible frame), which PDFKit then paginates across paper pages.
            let config = WKPDFConfiguration()
            config.rect = nil

            webView.createPDF(configuration: config) { [self] result in
                defer { PrintRenderer.pending = nil }
                switch result {
                case .success(let data):
                    guard let pdf = PDFDocument(data: data) else {
                        NSLog("PrintRenderer: PDFDocument init failed")
                        return
                    }
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

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            NSLog("PrintRenderer: load failed: \(error)")
            PrintRenderer.pending = nil
        }
    }
}
