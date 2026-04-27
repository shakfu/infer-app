import XCTest
@testable import InferAgents

final class FilesystemListToolTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-list-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func makeTool() -> FilesystemListTool {
        FilesystemListTool(allowedRoots: [sandbox])
    }

    private func touch(_ relative: String) throws {
        let url = sandbox.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(relative.utf8).write(to: url)
    }

    private func decode(_ output: String) throws -> [[String: Any]] {
        let data = Data(output.utf8)
        let any = try JSONSerialization.jsonObject(with: data)
        return any as? [[String: Any]] ?? []
    }

    // MARK: - Sandbox

    func testRejectsPathOutsideSandbox() async throws {
        let json = ##"{"path": "/etc"}"##
        let result = try await makeTool().invoke(arguments: json)
        XCTAssertEqual(result.error, "path is outside the allowed sandbox")
    }

    func testRejectsMissingDirectory() async throws {
        let path = sandbox.appendingPathComponent("nope").path
        let json = ##"{"path": "\##(path)"}"##
        let result = try await makeTool().invoke(arguments: json)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("no such directory"))
    }

    func testRejectsFileTarget() async throws {
        try touch("a.txt")
        let json = ##"{"path": "\##(sandbox.path)/a.txt"}"##
        let result = try await makeTool().invoke(arguments: json)
        XCTAssertEqual(result.error, "path is a file, not a directory")
    }

    // MARK: - Listing

    func testListsTopLevelEntriesAlphabetically() async throws {
        try touch("c.md")
        try touch("a.md")
        try touch("b.md")
        let json = ##"{"path": "\##(sandbox.path)"}"##
        let result = try await makeTool().invoke(arguments: json)
        XCTAssertNil(result.error)
        let entries = try decode(result.output)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0]["name"] as? String, "a.md")
        XCTAssertEqual(entries[1]["name"] as? String, "b.md")
        XCTAssertEqual(entries[2]["name"] as? String, "c.md")
    }

    func testHidesDotfilesByDefault() async throws {
        try touch(".hidden")
        try touch("visible.md")
        let json = ##"{"path": "\##(sandbox.path)"}"##
        let result = try await makeTool().invoke(arguments: json)
        let entries = try decode(result.output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["name"] as? String, "visible.md")
    }

    func testIncludeHiddenSurfacesDotfiles() async throws {
        try touch(".hidden")
        try touch("visible.md")
        let json = ##"{"path": "\##(sandbox.path)", "includeHidden": true}"##
        let result = try await makeTool().invoke(arguments: json)
        let entries = try decode(result.output)
        XCTAssertEqual(entries.count, 2)
    }

    func testExtensionFilter() async throws {
        try touch("notes.md")
        try touch("notes.txt")
        try touch("ignored.png")
        // Filter accepts both "md" and ".md" forms; tool normalises.
        let json = ##"{"path": "\##(sandbox.path)", "extensions": [".md", "txt"]}"##
        let result = try await makeTool().invoke(arguments: json)
        let entries = try decode(result.output)
        let names = entries.compactMap { $0["name"] as? String }.sorted()
        XCTAssertEqual(names, ["notes.md", "notes.txt"])
    }

    func testExtensionFilterPassesDirectoriesThrough() async throws {
        try touch("notes.md")
        try touch("nested/inner.md")
        // With recursive=false, the `nested/` dir entry surfaces even
        // though it doesn't match `extensions` (filter applies to
        // files only).
        let json = ##"{"path": "\##(sandbox.path)", "extensions": ["md"]}"##
        let result = try await makeTool().invoke(arguments: json)
        let entries = try decode(result.output)
        let names = entries.compactMap { $0["name"] as? String }.sorted()
        XCTAssertEqual(names, ["nested", "notes.md"])
    }

    func testRecursiveDescent() async throws {
        try touch("a.md")
        try touch("d1/b.md")
        try touch("d1/d2/c.md")
        let json = ##"{"path": "\##(sandbox.path)", "recursive": true}"##
        let result = try await makeTool().invoke(arguments: json)
        let entries = try decode(result.output)
        let names = Set(entries.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("a.md"))
        XCTAssertTrue(names.contains("b.md"))
        XCTAssertTrue(names.contains("c.md"))
        XCTAssertTrue(names.contains("d1"))
        XCTAssertTrue(names.contains("d2"))
    }

    // MARK: - Caps

    func testEntryCapTruncates() async throws {
        for i in 0..<(FilesystemListTool.maxEntries + 5) {
            try touch(String(format: "f%04d.md", i))
        }
        let json = ##"{"path": "\##(sandbox.path)"}"##
        let result = try await makeTool().invoke(arguments: json)
        let entries = try decode(result.output)
        // Final element is the truncation marker; entries before it
        // sum to maxEntries.
        XCTAssertEqual(entries.count, FilesystemListTool.maxEntries + 1)
        XCTAssertEqual(entries.last?["truncated"] as? Bool, true)
    }

    func testDepthCapStopsRecursion() async throws {
        // depth 1 (sandbox/d1), 2 (d2), 3 (d3), 4 (d4), 5 (d5) — beyond
        // maxDepth (4), so contents of d4 are listed but d5 is not
        // descended into.
        try touch("d1/d2/d3/d4/d5/leaf.md")
        let json = ##"{"path": "\##(sandbox.path)", "recursive": true}"##
        let result = try await makeTool().invoke(arguments: json)
        let entries = try decode(result.output)
        let names = Set(entries.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("d1"))
        XCTAssertTrue(names.contains("d4"))
        XCTAssertFalse(names.contains("leaf.md"), "leaf at depth 5 should be cut by depth cap")
    }
}
