import XCTest
@testable import InferAgents

/// Round-trip tests: `xlsx.write` produces a fixture, `xlsx.read`
/// reads it back. Validates that both tools agree on the wire format
/// — bugs that show up in only one direction (e.g. the writer
/// stamping a string as a number, or the reader misclassifying a
/// boolean) get caught here.
final class XlsxReadToolTests: XCTestCase {
    private var sandbox: URL!
    private var writeTool: XlsxWriteTool!
    private var readTool: XlsxReadTool!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("xlsx-read-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        writeTool = XlsxWriteTool(allowedRoots: [sandbox])
        readTool = XlsxReadTool(allowedRoots: [sandbox])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// Helper: write `sheets` and return the resulting URL on disk.
    private func writeFixture(_ name: String, sheets: [[String: Any]]) async throws -> URL {
        let target = sandbox.appendingPathComponent(name)
        let payload: [String: Any] = ["path": target.path, "sheets": sheets]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(decoding: data, as: UTF8.self)
        let result = try await writeTool.invoke(arguments: json)
        XCTAssertNil(result.error, "write fixture failed: \(result.error ?? "")")
        return target
    }

    private func readJSON(_ url: URL, sheet: String? = nil) async throws -> [[String]] {
        var args: [String: Any] = ["path": url.path, "format": "json"]
        if let sheet = sheet { args["sheet"] = sheet }
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await readTool.invoke(arguments: String(decoding: data, as: UTF8.self))
        XCTAssertNil(result.error, "read failed: \(result.error ?? "")")
        let parsed = try JSONSerialization.jsonObject(with: Data(result.output.utf8))
        return parsed as? [[String]] ?? []
    }

    // MARK: - Argument validation / sandbox

    func testRejectsPathOutsideSandbox() async throws {
        let result = try await readTool.invoke(arguments: ##"{"path": "/etc/passwd"}"##)
        XCTAssertEqual(result.error, "path is outside the allowed sandbox")
    }

    func testRejectsMissingFile() async throws {
        let path = sandbox.appendingPathComponent("nope.xlsx").path
        let json = ##"{"path": "\##(path)"}"##
        let result = try await readTool.invoke(arguments: json)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("no such file"))
    }

    func testRejectsDirectory() async throws {
        let result = try await readTool.invoke(arguments: ##"{"path": "\##(sandbox.path)"}"##)
        XCTAssertEqual(result.error, "path is a directory, not a file")
    }

    func testRejectsNonXlsx() async throws {
        let notXlsx = sandbox.appendingPathComponent("plain.txt")
        try "hello".write(to: notXlsx, atomically: true, encoding: .utf8)
        let result = try await readTool.invoke(arguments: ##"{"path": "\##(notXlsx.path)"}"##)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("could not open as xlsx"))
    }

    // MARK: - Round-trip core types

    func testRoundTripStringsAndNumbers() async throws {
        let url = try await writeFixture("simple.xlsx", sheets: [[
            "name": "Sheet1",
            "header": ["q", "rev"],
            "rows": [["Q1", 12500], ["Q2", 14200], ["Q3", 9800]]
        ]])
        let matrix = try await readJSON(url)
        XCTAssertEqual(matrix.count, 4)
        XCTAssertEqual(matrix[0], ["q", "rev"])
        XCTAssertEqual(matrix[1], ["Q1", "12500"])
        XCTAssertEqual(matrix[2], ["Q2", "14200"])
        XCTAssertEqual(matrix[3], ["Q3", "9800"])
    }

    func testRoundTripBooleans() async throws {
        let url = try await writeFixture("bools.xlsx", sheets: [[
            "name": "B",
            "rows": [[true, false], [false, true]]
        ]])
        let matrix = try await readJSON(url)
        XCTAssertEqual(matrix, [["TRUE", "FALSE"], ["FALSE", "TRUE"]])
    }

    func testRoundTripFloats() async throws {
        let url = try await writeFixture("floats.xlsx", sheets: [[
            "name": "F",
            "rows": [[1.5, 2.5], [-3.25, 0.125]]
        ]])
        let matrix = try await readJSON(url)
        // CoreXLSX returns the raw value string from the XML; the
        // exact representation depends on libxlsxwriter's output. We
        // check the parsed numeric value, not the string form.
        XCTAssertEqual(matrix.count, 2)
        XCTAssertEqual(Double(matrix[0][0]), 1.5)
        XCTAssertEqual(Double(matrix[0][1]), 2.5)
        XCTAssertEqual(Double(matrix[1][0]), -3.25)
        XCTAssertEqual(Double(matrix[1][1]), 0.125)
    }

    func testRoundTripStringsWithSpecialCharacters() async throws {
        // Strings containing characters that some xlsx writers
        // mishandle: ampersands, quotes, accents, emoji. Verify all
        // pass through write→read losslessly.
        let url = try await writeFixture("special.xlsx", sheets: [[
            "name": "X",
            "rows": [["a & b", "she said \"hi\""], ["café", "🚀"]]
        ]])
        let matrix = try await readJSON(url)
        XCTAssertEqual(matrix, [
            ["a & b", "she said \"hi\""],
            ["café", "🚀"]
        ])
    }

    // MARK: - Sheet selection

    func testReadsFirstSheetByDefault() async throws {
        let url = try await writeFixture("multi.xlsx", sheets: [
            ["name": "First", "rows": [["alpha"]]],
            ["name": "Second", "rows": [["beta"]]]
        ])
        let matrix = try await readJSON(url)
        XCTAssertEqual(matrix, [["alpha"]])
    }

    func testReadsSpecifiedSheet() async throws {
        let url = try await writeFixture("multi.xlsx", sheets: [
            ["name": "First", "rows": [["alpha"]]],
            ["name": "Second", "rows": [["beta"]]]
        ])
        let matrix = try await readJSON(url, sheet: "Second")
        XCTAssertEqual(matrix, [["beta"]])
    }

    func testMissingSheetSurfacesAvailableNames() async throws {
        let url = try await writeFixture("multi.xlsx", sheets: [
            ["name": "First", "rows": [["alpha"]]],
            ["name": "Second", "rows": [["beta"]]]
        ])
        let json = ##"{"path": "\##(url.path)", "sheet": "Nope", "format": "json"}"##
        let result = try await readTool.invoke(arguments: json)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("no sheet named 'Nope'"))
        XCTAssertTrue(result.error!.contains("First"))
        XCTAssertTrue(result.error!.contains("Second"))
    }

    // MARK: - TSV format

    func testTSVFormatRoundTrips() async throws {
        let url = try await writeFixture("tsv.xlsx", sheets: [[
            "name": "Sheet1",
            "header": ["a", "b"],
            "rows": [["1", 2], ["3", 4]]
        ]])
        let json = ##"{"path": "\##(url.path)", "format": "tsv"}"##
        let result = try await readTool.invoke(arguments: json)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "a\tb\n1\t2\n3\t4")
    }

    func testTSVFormatSanitisesEmbeddedTabs() async throws {
        // A cell containing an embedded tab should be sanitised to a
        // space — same convention as `tsv.write` so the round-trip
        // shape is symmetric.
        let url = try await writeFixture("tabs.xlsx", sheets: [[
            "name": "T",
            "rows": [["with\ttab", "ok"]]
        ]])
        let json = ##"{"path": "\##(url.path)", "format": "tsv"}"##
        let result = try await readTool.invoke(arguments: json)
        XCTAssertEqual(result.output, "with tab\tok")
    }

    // MARK: - Slicing / caps

    func testMaxRowsClipsSlice() async throws {
        let bigRows: [[Any]] = (1...50).map { ["row \($0)", $0] }
        let url = try await writeFixture("big.xlsx", sheets: [[
            "name": "B", "rows": bigRows
        ]])
        let json = ##"{"path": "\##(url.path)", "format": "json", "maxRows": 5}"##
        let result = try await readTool.invoke(arguments: json)
        let matrix = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String]] ?? []
        XCTAssertEqual(matrix.count, 5)
        XCTAssertEqual(matrix[0][0], "row 1")
        XCTAssertEqual(matrix[4][0], "row 5")
    }

    func testMaxColsClipsSlice() async throws {
        let url = try await writeFixture("wide.xlsx", sheets: [[
            "name": "W",
            "rows": [["a", "b", "c", "d", "e", "f"]]
        ]])
        let json = ##"{"path": "\##(url.path)", "format": "json", "maxCols": 3}"##
        let result = try await readTool.invoke(arguments: json)
        let matrix = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String]] ?? []
        XCTAssertEqual(matrix, [["a", "b", "c"]])
    }

    // MARK: - Column-index helper

    func testColumnIndexMath() {
        XCTAssertEqual(XlsxReadTool.columnIndex(from: "A"), 0)
        XCTAssertEqual(XlsxReadTool.columnIndex(from: "B"), 1)
        XCTAssertEqual(XlsxReadTool.columnIndex(from: "Z"), 25)
        XCTAssertEqual(XlsxReadTool.columnIndex(from: "AA"), 26)
        XCTAssertEqual(XlsxReadTool.columnIndex(from: "AB"), 27)
        XCTAssertEqual(XlsxReadTool.columnIndex(from: "BA"), 52)
        XCTAssertEqual(XlsxReadTool.columnIndex(from: "ZZ"), 701)
        XCTAssertEqual(XlsxReadTool.columnIndex(from: "AAA"), 702)
        // Lowercase passes (defensive — Excel always emits uppercase
        // but the parser in Swift might see either).
        XCTAssertEqual(XlsxReadTool.columnIndex(from: "a"), 0)
    }
}
