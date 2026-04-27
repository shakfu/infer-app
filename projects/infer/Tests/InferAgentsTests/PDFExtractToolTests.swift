import XCTest
import PDFKit
import CoreText
import AppKit
@testable import InferAgents

final class PDFExtractToolTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-extract-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// Generate a minimal multi-page PDF by drawing each `pages` string
    /// into its own PDF page. Uses CoreGraphics' PDF context + CoreText
    /// glyph rendering so the produced bytes have a real text layer
    /// PDFKit can extract — the alternative (a zero-page or blank-page
    /// PDF) wouldn't exercise the extraction path at all.
    private func writePDF(pages: [String], to url: URL) throws {
        let mutable = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutable) else {
            throw NSError(domain: "test", code: -1)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "test", code: -1)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for text in pages {
            ctx.beginPDFPage(nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                .foregroundColor: NSColor.black,
            ]
            let attrString = NSAttributedString(string: text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrString)
            ctx.textPosition = CGPoint(x: 50, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try mutable.write(to: url)
    }

    private func makeTool() -> PDFExtractTool {
        PDFExtractTool(allowedRoots: [sandbox])
    }

    // MARK: - Argument validation / sandbox

    func testRejectsMalformedArguments() async throws {
        let tool = makeTool()
        let result = try await tool.invoke(arguments: "not-json")
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
    }

    func testRejectsEmptyAllowedRoots() async throws {
        let tool = PDFExtractTool(allowedRoots: [])
        let result = try await tool.invoke(arguments: ##"{"path": "/tmp/whatever.pdf"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(result.error, "pdf.extract is not configured: no allowed roots")
    }

    func testRejectsPathOutsideSandbox() async throws {
        let tool = makeTool()
        let result = try await tool.invoke(arguments: ##"{"path": "/etc/hosts"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(result.error, "path is outside the allowed sandbox")
    }

    func testRejectsMissingFile() async throws {
        let tool = makeTool()
        let path = sandbox.appendingPathComponent("nope.pdf").path
        let json = ##"{"path": "\##(path)"}"##
        let result = try await tool.invoke(arguments: json)
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("no such file"))
    }

    func testRejectsDirectory() async throws {
        let tool = makeTool()
        let result = try await tool.invoke(arguments: ##"{"path": "\##(sandbox.path)"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(result.error, "path is a directory, not a file")
    }

    func testRejectsNonPDF() async throws {
        let notPDF = sandbox.appendingPathComponent("plain.txt")
        try "hello".write(to: notPDF, atomically: true, encoding: .utf8)
        let tool = makeTool()
        let result = try await tool.invoke(arguments: ##"{"path": "\##(notPDF.path)"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("could not open as PDF"))
    }

    // MARK: - Extraction

    func testExtractsAllPagesByDefault() async throws {
        let pdf = sandbox.appendingPathComponent("doc.pdf")
        try writePDF(pages: ["alpha page", "beta page", "gamma page"], to: pdf)
        let tool = makeTool()
        let result = try await tool.invoke(arguments: ##"{"path": "\##(pdf.path)"}"##)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.output.contains("--- Page 1 ---"))
        XCTAssertTrue(result.output.contains("alpha page"))
        XCTAssertTrue(result.output.contains("--- Page 2 ---"))
        XCTAssertTrue(result.output.contains("beta page"))
        XCTAssertTrue(result.output.contains("--- Page 3 ---"))
        XCTAssertTrue(result.output.contains("gamma page"))
        // Order: page 1 must precede page 2 in the assembled output.
        let r1 = result.output.range(of: "--- Page 1 ---")!
        let r2 = result.output.range(of: "--- Page 2 ---")!
        XCTAssertLessThan(r1.lowerBound, r2.lowerBound)
    }

    func testExtractsSpecificPage() async throws {
        let pdf = sandbox.appendingPathComponent("doc.pdf")
        try writePDF(pages: ["alpha page", "beta page", "gamma page"], to: pdf)
        let tool = makeTool()
        let result = try await tool.invoke(arguments: ##"{"path": "\##(pdf.path)", "pageRange": "2"}"##)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.output.contains("--- Page 2 ---"))
        XCTAssertTrue(result.output.contains("beta page"))
        XCTAssertFalse(result.output.contains("alpha page"))
        XCTAssertFalse(result.output.contains("gamma page"))
    }

    func testExtractsRange() async throws {
        let pdf = sandbox.appendingPathComponent("doc.pdf")
        try writePDF(pages: (1...5).map { "content \($0)" }, to: pdf)
        let tool = makeTool()
        let result = try await tool.invoke(arguments: ##"{"path": "\##(pdf.path)", "pageRange": "2-4"}"##)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.output.contains("content 2"))
        XCTAssertTrue(result.output.contains("content 3"))
        XCTAssertTrue(result.output.contains("content 4"))
        XCTAssertFalse(result.output.contains("content 1"))
        XCTAssertFalse(result.output.contains("content 5"))
    }

    func testExtractsCommaSeparatedAndRangeMix() async throws {
        let pdf = sandbox.appendingPathComponent("doc.pdf")
        try writePDF(pages: (1...7).map { "content \($0)" }, to: pdf)
        let tool = makeTool()
        let result = try await tool.invoke(arguments: ##"{"path": "\##(pdf.path)", "pageRange": "1,3-4,7"}"##)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.output.contains("content 1"))
        XCTAssertTrue(result.output.contains("content 3"))
        XCTAssertTrue(result.output.contains("content 4"))
        XCTAssertTrue(result.output.contains("content 7"))
        XCTAssertFalse(result.output.contains("content 2"))
        XCTAssertFalse(result.output.contains("content 5"))
        XCTAssertFalse(result.output.contains("content 6"))
    }

    func testInvalidPageRangeReturnsError() async throws {
        let pdf = sandbox.appendingPathComponent("doc.pdf")
        try writePDF(pages: ["x", "y"], to: pdf)
        let tool = makeTool()
        let result = try await tool.invoke(arguments: ##"{"path": "\##(pdf.path)", "pageRange": "abc"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
    }

    func testOutOfRangePagesGetClamped() async throws {
        let pdf = sandbox.appendingPathComponent("doc.pdf")
        try writePDF(pages: ["only page"], to: pdf)
        let tool = makeTool()
        // Range extends past the end — clamped silently to existing pages.
        let result = try await tool.invoke(arguments: ##"{"path": "\##(pdf.path)", "pageRange": "1-99"}"##)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.output.contains("only page"))
    }

    func testRangeSelectingZeroPagesReturnsError() async throws {
        let pdf = sandbox.appendingPathComponent("doc.pdf")
        try writePDF(pages: ["one"], to: pdf)
        let tool = makeTool()
        // Page 5 doesn't exist in a 1-page PDF; nothing selected.
        let result = try await tool.invoke(arguments: ##"{"path": "\##(pdf.path)", "pageRange": "5"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("selected no pages"))
    }

    // MARK: - Page-range parser unit tests

    func testParsePageRangeAll() {
        let cases = [nil, "", " ", "all", "ALL"]
        for raw in cases {
            switch PDFExtractTool.parsePageRange(raw, totalPages: 5) {
            case .ok(let indices):
                XCTAssertEqual(indices, [0, 1, 2, 3, 4], "input \(raw ?? "nil")")
            case .invalid:
                XCTFail("expected ok for \(raw ?? "nil")")
            }
        }
    }

    func testParsePageRangeSinglePage() {
        guard case .ok(let indices) = PDFExtractTool.parsePageRange("3", totalPages: 5) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(indices, [2])
    }

    func testParsePageRangeRange() {
        guard case .ok(let indices) = PDFExtractTool.parsePageRange("2-4", totalPages: 10) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(indices, [1, 2, 3])
    }

    func testParsePageRangeMixed() {
        guard case .ok(let indices) = PDFExtractTool.parsePageRange("1,3-5,8", totalPages: 10) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(indices, [0, 2, 3, 4, 7])
    }

    func testParsePageRangeDeduplicates() {
        guard case .ok(let indices) = PDFExtractTool.parsePageRange("1,1,2-3,3", totalPages: 5) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(indices, [0, 1, 2])
    }

    func testParsePageRangeRejectsZero() {
        guard case .invalid = PDFExtractTool.parsePageRange("0", totalPages: 5) else {
            return XCTFail("expected invalid")
        }
    }

    func testParsePageRangeRejectsReversedRange() {
        guard case .invalid = PDFExtractTool.parsePageRange("5-2", totalPages: 10) else {
            return XCTFail("expected invalid")
        }
    }

    func testParsePageRangeRejectsGarbage() {
        guard case .invalid = PDFExtractTool.parsePageRange("hello", totalPages: 5) else {
            return XCTFail("expected invalid")
        }
    }
}
