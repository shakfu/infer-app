import CoreText
import XCTest
@testable import Infer

final class RemoteSourceLoaderTests: XCTestCase {
    private func session(body: Data, status: Int = 200, contentType: String, contentLength: Int? = nil) -> URLSession {
        RemoteSourceStubProtocol.response = (body, status, contentType, contentLength)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteSourceStubProtocol.self]
        return URLSession(configuration: config)
    }

    private func assertFails(
        _ url: String = "https://x.test/a",
        body: Data = Data("x".utf8),
        status: Int = 200,
        contentType: String = "text/plain",
        contains text: String,
        line: UInt = #line
    ) async {
        do {
            _ = try await RemoteSourceLoader.load(url, session: session(body: body, status: status, contentType: contentType))
            XCTFail("expected throw", line: line)
        } catch {
            XCTAssertTrue("\(error)".contains(text), "got \(error)", line: line)
        }
    }

    func testHTMLBecomesPlainText() async throws {
        let html = "<html><head><title>T</title></head><body><script>evil()</script><h1>Title</h1><p>One &amp; two</p></body></html>"
        let (source, _) = try await RemoteSourceLoader.load(
            "https://x.test/a",
            session: session(body: Data(html.utf8), contentType: "text/html; charset=utf-8")
        )
        XCTAssertEqual(source.kind, "url")
        XCTAssertEqual(source.content, "Title\n\nOne & two")
    }

    func testMarkdownAndJSONStayVerbatim() async throws {
        for (text, type) in [("# A\n<b>x</b>", "text/markdown"), (#"{"a":1}"#, "application/json")] {
            let (source, _) = try await RemoteSourceLoader.load(
                "https://x.test/a",
                session: session(body: Data(text.utf8), contentType: type)
            )
            XCTAssertEqual(source.content, text)
        }
    }

    func testHashFollowsBody() async throws {
        func hash(_ text: String) async throws -> String {
            try await RemoteSourceLoader.load(
                "https://x.test/a",
                session: session(body: Data(text.utf8), contentType: "text/plain")
            ).1
        }
        let first = try await hash("one")
        let same = try await hash("one")
        let other = try await hash("two")
        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, other)
    }

    func testRejectsNonWebURLs() async {
        for url in ["file:///etc/passwd", "ftp://x.test/a", "not a url", "https://"] {
            await assertFails(url, contains: "http or https")
        }
    }

    func testRejectsHTTPErrors() async {
        await assertFails(status: 404, contains: "HTTP 404")
    }

    func testRejectsBinaryContentTypes() async {
        await assertFails(contentType: "application/zip", contains: "application/zip")
    }

    private func assertTooLarge(_ session: URLSession, line: UInt = #line) async {
        do {
            _ = try await RemoteSourceLoader.load("https://x.test/a", session: session, textLimit: 8)
            XCTFail("expected throw", line: line)
        } catch {
            XCTAssertTrue("\(error)".contains("exceeds 8 bytes"), "got \(error)", line: line)
        }
    }

    func testRejectsOversizeBodyWithoutAContentLength() async {
        await assertTooLarge(session(body: Data("123456789".utf8), contentType: "text/plain"))
    }

    func testRejectsDeclaredOversizeBeforeReading() async {
        await assertTooLarge(session(body: Data("small".utf8), contentType: "text/plain", contentLength: 9))
    }

    func testBodyAtTheLimitIsAccepted() async throws {
        let (source, _) = try await RemoteSourceLoader.load(
            "https://x.test/a",
            session: session(body: Data("12345678".utf8), contentType: "text/plain"),
            textLimit: 8
        )
        XCTAssertEqual(source.content, "12345678")
    }

    // MARK: - Encodings

    private func decoded(_ bytes: [UInt8], _ contentType: String) async throws -> String {
        try await RemoteSourceLoader.load(
            "https://x.test/a",
            session: session(body: Data(bytes), contentType: contentType)
        ).0.content
    }

    private let cafeLatin1: [UInt8] = [0x63, 0x61, 0x66, 0xE9]

    func testUsesDeclaredCharset() async throws {
        let text = try await decoded(cafeLatin1, "text/plain; charset=iso-8859-1")
        XCTAssertEqual(text, "caf\u{E9}")
        let utf16 = try await decoded(Array("hi".data(using: .utf16LittleEndian)!), "text/plain; charset=utf-16le")
        XCTAssertEqual(utf16, "hi")
    }

    func testFallsBackFromAWrongCharsetAndAnUnknownOne() async throws {
        let wrong = try await decoded(cafeLatin1, "text/plain; charset=utf-8")
        XCTAssertEqual(wrong, "caf\u{E9}")
        let unknown = try await decoded(cafeLatin1, "text/plain; charset=nonsense")
        XCTAssertEqual(unknown, "caf\u{E9}")
    }

    func testUsesHTMLMetaCharset() async throws {
        // 0xC0 0xC1 is two Cyrillic letters in KOI8-R and invalid in UTF-8.
        let html = Array(#"<meta charset="koi8-r"><p>"#.utf8) + [0xC0, 0xC1]
        let text = try await decoded(html, "text/html")
        XCTAssertEqual(text, "\u{44E}\u{430}")
    }

    func testUndeclaredBytesFallBackToWindows1252() async throws {
        let text = try await decoded([0x93, 0x41, 0x94], "text/plain")
        XCTAssertEqual(text, "\u{201C}A\u{201D}")
    }

    // MARK: - PDF

    func testPDFBodyBecomesText() async throws {
        let (source, _) = try await RemoteSourceLoader.load(
            "https://x.test/a.pdf",
            session: session(body: try makePDF(pages: ["Alpha", "Beta"]), contentType: "application/pdf")
        )
        XCTAssertEqual(source.content, "Alpha\n\nBeta")
    }

    func testPDFWithoutTextIsRejected() async throws {
        await assertFails(body: try makePDF(pages: [""]), contentType: "application/pdf", contains: "no text layer")
    }

    func testCorruptPDFIsRejected() async {
        await assertFails(body: Data("not a pdf".utf8), contentType: "application/pdf", contains: "could not be opened")
    }

    func testPDFHasItsOwnSizeLimit() async throws {
        let pdf = try makePDF(pages: ["Alpha"])
        let pass = try await RemoteSourceLoader.load(
            "https://x.test/a.pdf",
            session: session(body: pdf, contentType: "application/pdf"),
            textLimit: 8
        )
        XCTAssertEqual(pass.0.content, "Alpha")
        do {
            _ = try await RemoteSourceLoader.load(
                "https://x.test/a.pdf",
                session: session(body: pdf, contentType: "application/pdf"),
                pdfLimit: 8
            )
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue("\(error)".contains("exceeds 8 bytes"), "got \(error)")
        }
    }

    func testFilePDFLoadsThroughSourceLoader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let good = dir.appendingPathComponent("a.PDF")
        try makePDF(pages: ["Alpha"]).write(to: good)
        XCTAssertTrue(SourceLoader.isSupported(good))
        let loaded = try SourceLoader.load(good)
        XCTAssertEqual(loaded.kind, "pdf")
        XCTAssertEqual(loaded.content, "Alpha")

        let scan = dir.appendingPathComponent("scan.pdf")
        try makePDF(pages: [""]).write(to: scan)
        XCTAssertThrowsError(try SourceLoader.load(scan)) {
            XCTAssertTrue("\($0)".contains("no text layer"))
        }
        let corrupt = dir.appendingPathComponent("bad.pdf")
        try Data("nope".utf8).write(to: corrupt)
        XCTAssertThrowsError(try SourceLoader.load(corrupt)) {
            XCTAssertTrue("\($0)".contains("could not be opened"))
        }
    }

    private func makePDF(pages: [String]) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw NSError(domain: "test", code: 1) }
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            context.textPosition = CGPoint(x: 50, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    func testRejectsPageWithNoText() async {
        await assertFails(body: Data("<script>x()</script>".utf8), contentType: "text/html", contains: "no text")
    }
}

private final class RemoteSourceStubProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (body: Data, status: Int, contentType: String, contentLength: Int?) = (Data(), 200, "", nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (body, status, contentType, contentLength) = Self.response
        var headers = ["Content-Type": contentType]
        if let contentLength { headers["Content-Length"] = String(contentLength) }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
