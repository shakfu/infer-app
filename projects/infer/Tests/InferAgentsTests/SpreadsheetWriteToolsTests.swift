import XCTest
@testable import InferAgents

final class SpreadsheetWriteToolsTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("spreadsheet-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - Cell decoding (shared)

    func testCellDecodesScalarTypes() {
        XCTAssertEqual(XlsxWorksheet.Cell.decode("hello").map(text), "hello")
        XCTAssertEqual(XlsxWorksheet.Cell.decode("=SUM(A1:A3)").map(formula), "=SUM(A1:A3)")
        XCTAssertEqual(XlsxWorksheet.Cell.decode(NSNumber(value: 42)).map(number), 42.0)
        XCTAssertEqual(XlsxWorksheet.Cell.decode(NSNumber(value: 3.14)).map(number), 3.14)
        XCTAssertEqual(XlsxWorksheet.Cell.decode(NSNumber(value: true)).map(bool), true)
        XCTAssertEqual(XlsxWorksheet.Cell.decode(NSNumber(value: false)).map(bool), false)
        XCTAssertNil(XlsxWorksheet.Cell.decode(["nested"]))
        XCTAssertNil(XlsxWorksheet.Cell.decode(["k": "v"]))
        if case .empty = XlsxWorksheet.Cell.decode(NSNull())! {} else { XCTFail("nil should decode to .empty") }
    }

    private func text(_ c: XlsxWorksheet.Cell) -> String? { if case .text(let s) = c { return s } else { return nil } }
    private func formula(_ c: XlsxWorksheet.Cell) -> String? { if case .formula(let s) = c { return s } else { return nil } }
    private func number(_ c: XlsxWorksheet.Cell) -> Double? { if case .number(let n) = c { return n } else { return nil } }
    private func bool(_ c: XlsxWorksheet.Cell) -> Bool? { if case .bool(let b) = c { return b } else { return nil } }

    // MARK: - csv.write

    func testCSVWriteHappyPath() async throws {
        let tool = CSVWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("out.csv")
        let json = ##"""
        {"path": "\##(target.path)", "rows": [["a", "b"], ["1", 2]], "bom": false}
        """##
        let result = try await tool.invoke(arguments: json)
        XCTAssertNil(result.error)
        let body = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(body, "a,b\r\n1,2\r\n")
    }

    func testCSVEscapingPerRFC4180() {
        // Verifies the static escape function — RFC 4180 quotes any
        // cell containing the delimiter, a double quote, or a line
        // break, and doubles internal quotes.
        XCTAssertEqual(CSVWriteTool.escape("simple"), "simple")
        XCTAssertEqual(CSVWriteTool.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVWriteTool.escape("she said \"hi\""), "\"she said \"\"hi\"\"\"")
        XCTAssertEqual(CSVWriteTool.escape("line\nbreak"), "\"line\nbreak\"")
        XCTAssertEqual(CSVWriteTool.escape("with\rcr"), "\"with\rcr\"")
    }

    func testCSVBOMByDefault() async throws {
        let tool = CSVWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("with-bom.csv")
        let json = ##"""
        {"path": "\##(target.path)", "rows": [["a", "b"]]}
        """##
        let result = try await tool.invoke(arguments: json)
        XCTAssertNil(result.error)
        let raw = try Data(contentsOf: target)
        XCTAssertEqual(Array(raw.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    func testCSVRefusesNonRectangular() async throws {
        let tool = CSVWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("bad.csv")
        let json = ##"""
        {"path": "\##(target.path)", "rows": [["a", "b"], ["c"]]}
        """##
        let result = try await tool.invoke(arguments: json)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("rectangular"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "non-rectangular rows should not produce a partial file")
    }

    func testCSVRefusesPathOutsideSandbox() async throws {
        let tool = CSVWriteTool(allowedRoots: [sandbox])
        let result = try await tool.invoke(
            arguments: ##"{"path": "/etc/escape.csv", "rows": [["x"]]}"##
        )
        XCTAssertEqual(result.error, "path is outside the allowed sandbox")
    }

    func testCSVRefusesOverwriteByDefault() async throws {
        let tool = CSVWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("exists.csv")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let json = ##"""
        {"path": "\##(target.path)", "rows": [["new"]]}
        """##
        let result = try await tool.invoke(arguments: json)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("file exists"))
    }

    func testCSVNumbersAndFormulas() async throws {
        let tool = CSVWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("nums.csv")
        let json = ##"""
        {"path": "\##(target.path)", "rows": [["q", "rev"], ["Q1", 12500], ["Q2", 14200], ["Total", "=SUM(B2:B3)"]], "bom": false}
        """##
        let result = try await tool.invoke(arguments: json)
        XCTAssertNil(result.error)
        let body = try String(contentsOf: target, encoding: .utf8)
        // Numbers serialise without trailing decimals; formulas pass through verbatim.
        XCTAssertTrue(body.contains("Q1,12500"))
        XCTAssertTrue(body.contains("Total,=SUM(B2:B3)"))
    }

    // MARK: - tsv.write

    func testTSVHappyPath() async throws {
        let tool = TSVWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("out.tsv")
        let json = ##"""
        {"path": "\##(target.path)", "rows": [["a", "b"], ["1", 2]]}
        """##
        let result = try await tool.invoke(arguments: json)
        XCTAssertNil(result.error)
        let body = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(body, "a\tb\n1\t2\n")
    }

    func testTSVSanitisesEmbeddedTabsAndNewlines() {
        XCTAssertEqual(TSVWriteTool.sanitise("plain"), "plain")
        XCTAssertEqual(TSVWriteTool.sanitise("with\ttab"), "with tab")
        XCTAssertEqual(TSVWriteTool.sanitise("multi\nline"), "multi line")
        XCTAssertEqual(TSVWriteTool.sanitise("cr\rlf\n\there"), "cr lf  here")
    }

    func testTSVDoesNotWriteBOM() async throws {
        let tool = TSVWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("nobom.tsv")
        let json = ##"""
        {"path": "\##(target.path)", "rows": [["x"]]}
        """##
        let result = try await tool.invoke(arguments: json)
        XCTAssertNil(result.error)
        let raw = try Data(contentsOf: target)
        XCTAssertNotEqual(Array(raw.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    // MARK: - xlsx.write

    /// Minimal smoke test: write a single-sheet xlsx, verify the file
    /// exists, has a valid ZIP header (xlsx is OOXML = a renamed zip),
    /// and is at least a few hundred bytes (a real xlsx with one row
    /// is ~5 KB).
    func testXlsxSingleSheet() async throws {
        let tool = XlsxWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("smoke.xlsx")
        let json = ##"""
        {
          "path": "\##(target.path)",
          "sheets": [
            {
              "name": "Smoke",
              "header": ["A", "B", "C"],
              "rows": [["one", 1, true], ["two", 2.5, false]],
              "freezeHeader": true
            }
          ]
        }
        """##
        let result = try await tool.invoke(arguments: json)
        XCTAssertNil(result.error, "got error: \(result.error ?? "")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        let data = try Data(contentsOf: target)
        // ZIP magic — every xlsx starts with the local-file-header
        // signature 0x504B0304 ("PK\x03\x04").
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertGreaterThan(data.count, 1024, "xlsx is suspiciously small (\(data.count) bytes)")
    }

    func testXlsxMultiSheetWithFormula() async throws {
        let tool = XlsxWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("multi.xlsx")
        let json = ##"""
        {
          "path": "\##(target.path)",
          "sheets": [
            {"name": "Q1-Q3", "header": ["Quarter", "Revenue"],
             "rows": [["Q1", 12500], ["Q2", 14200], ["Q3", 9800]]},
            {"name": "Summary",
             "rows": [["Total", "=SUM('Q1-Q3'!B2:B4)"], ["Average", "=AVERAGE('Q1-Q3'!B2:B4)"]]}
          ]
        }
        """##
        let result = try await tool.invoke(arguments: json)
        XCTAssertNil(result.error, "got error: \(result.error ?? "")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(result.output.contains("2 sheets"))
    }

    func testXlsxRejectsInvalidSheetName() async throws {
        let tool = XlsxWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("bad-name.xlsx")
        // Sheet names containing `:` are forbidden by Excel.
        let json = ##"""
        {"path": "\##(target.path)",
         "sheets": [{"name": "Bad:Name", "rows": [["x"]]}]}
        """##
        let result = try await tool.invoke(arguments: json)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("invalid sheet name"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "bad-name run should not leave a partial file")
    }

    func testXlsxRejectsEmptySheets() async throws {
        let tool = XlsxWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("empty.xlsx")
        let result = try await tool.invoke(arguments: ##"""
        {"path": "\##(target.path)", "sheets": []}
        """##)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("at least one"))
    }

    func testXlsxRefusesPathOutsideSandbox() async throws {
        let tool = XlsxWriteTool(allowedRoots: [sandbox])
        let result = try await tool.invoke(arguments: ##"""
        {"path": "/etc/escape.xlsx", "sheets": [{"rows": [["x"]]}]}
        """##)
        XCTAssertEqual(result.error, "path is outside the allowed sandbox")
    }

    func testXlsxAtomicWriteCleansUpOnFailure() async throws {
        // A run that fails mid-write (invalid sheet name) should not
        // leave a sibling temp file behind.
        let tool = XlsxWriteTool(allowedRoots: [sandbox])
        let target = sandbox.appendingPathComponent("atomic.xlsx")
        _ = try await tool.invoke(arguments: ##"""
        {"path": "\##(target.path)",
         "sheets": [{"name": "Bad/Name", "rows": [["x"]]}]}
        """##)
        let leftover = try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
            .filter { $0.hasPrefix(".") && $0.contains(target.lastPathComponent) }
        XCTAssertTrue(leftover.isEmpty, "leftover temp files: \(leftover)")
    }
}
