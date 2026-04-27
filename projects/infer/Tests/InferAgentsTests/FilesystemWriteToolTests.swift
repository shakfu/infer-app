import XCTest
@testable import InferAgents

final class FilesystemWriteToolTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-write-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func makeTool() -> FilesystemWriteTool {
        FilesystemWriteTool(allowedRoots: [sandbox])
    }

    // MARK: - Argument validation

    func testRejectsMalformedJSON() async throws {
        let result = try await makeTool().invoke(arguments: "not-json")
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
    }

    func testRejectsEmptyAllowedRoots() async throws {
        let tool = FilesystemWriteTool(allowedRoots: [])
        let json = ##"{"path": "/tmp/x", "content": "y"}"##
        let result = try await tool.invoke(arguments: json)
        XCTAssertEqual(result.error, "fs.write is not configured: no allowed roots")
    }

    // MARK: - Sandbox

    func testRejectsPathOutsideSandbox() async throws {
        let json = ##"{"path": "/tmp/escape.txt", "content": "x"}"##
        let result = try await makeTool().invoke(arguments: json)
        XCTAssertEqual(result.error, "path is outside the allowed sandbox")
    }

    // MARK: - Happy path

    func testWritesNewFile() async throws {
        let target = sandbox.appendingPathComponent("note.md")
        let json = ##"{"path": "\##(target.path)", "content": "hello world\n"}"##
        let result = try await makeTool().invoke(arguments: json)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.output.contains("wrote 12 bytes"))
        let read = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(read, "hello world\n")
    }

    // MARK: - Overwrite gate

    func testRefusesOverwriteByDefault() async throws {
        let target = sandbox.appendingPathComponent("note.md")
        try "original".write(to: target, atomically: true, encoding: .utf8)
        let json = ##"{"path": "\##(target.path)", "content": "replacement"}"##
        let result = try await makeTool().invoke(arguments: json)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("file exists"))
        // Original survives.
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
    }

    func testOverwritesWhenFlagged() async throws {
        let target = sandbox.appendingPathComponent("note.md")
        try "original".write(to: target, atomically: true, encoding: .utf8)
        let json = ##"{"path": "\##(target.path)", "content": "replacement", "overwrite": true}"##
        let result = try await makeTool().invoke(arguments: json)
        XCTAssertNil(result.error)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "replacement")
    }

    // MARK: - Type / structure rejections

    func testRefusesDirectoryTarget() async throws {
        let json = ##"{"path": "\##(sandbox.path)", "content": "x"}"##
        let result = try await makeTool().invoke(arguments: json)
        XCTAssertEqual(result.error, "path is a directory, not a file")
    }

    func testRefusesMissingParent() async throws {
        let target = sandbox.appendingPathComponent("nope/sub/file.md")
        let json = ##"{"path": "\##(target.path)", "content": "x"}"##
        let result = try await makeTool().invoke(arguments: json)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("parent directory does not exist"))
    }

    // MARK: - Size cap

    func testRefusesOversizeContent() async throws {
        let target = sandbox.appendingPathComponent("big.txt")
        let oversize = String(repeating: "a", count: FilesystemWriteTool.maxBytes + 1)
        // Build the JSON manually because string interpolation through
        // Swift's raw-string would re-escape.
        let payload: [String: Any] = ["path": target.path, "content": oversize]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(decoding: data, as: UTF8.self)
        let result = try await makeTool().invoke(arguments: json)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("exceeds"))
    }
}
