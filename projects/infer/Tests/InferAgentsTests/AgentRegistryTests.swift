import XCTest
@testable import InferAgents
@testable import InferCore

private struct FakeAgent: Agent {
    let id: AgentID
    let metadata: AgentMetadata
    let requirements = AgentRequirements()
    let tag: String

    init(id: AgentID, tag: String) {
        self.id = id
        self.metadata = AgentMetadata(name: "Fake \(tag)")
        self.tag = tag
    }

    func decodingParams(for context: AgentContext) -> DecodingParams {
        DecodingParams(from: .defaults)
    }
    func systemPrompt(for context: AgentContext) async throws -> String { tag }
}

final class AgentRegistryTests: XCTestCase {
    func testFirstRegistrationWins() async {
        let reg = AgentRegistry()
        await reg.register(FakeAgent(id: "a", tag: "first"), source: .firstParty)
        let entry = await reg.entry(id: "a")
        XCTAssertEqual(entry?.source, .firstParty)
    }

    func testUserOverridesPluginOverridesFirstParty() async {
        let reg = AgentRegistry()
        await reg.register(FakeAgent(id: "a", tag: "first"), source: .firstParty)
        await reg.register(FakeAgent(id: "a", tag: "plug"), source: .plugin)
        var entry = await reg.entry(id: "a")
        XCTAssertEqual(entry?.source, .plugin)
        XCTAssertEqual((entry?.agent as? FakeAgent)?.tag, "plug")

        await reg.register(FakeAgent(id: "a", tag: "user"), source: .user)
        entry = await reg.entry(id: "a")
        XCTAssertEqual(entry?.source, .user)
        XCTAssertEqual((entry?.agent as? FakeAgent)?.tag, "user")
    }

    func testLowerPrecedenceDoesNotReplaceHigher() async {
        let reg = AgentRegistry()
        await reg.register(FakeAgent(id: "a", tag: "user"), source: .user)
        let registered = await reg.register(
            FakeAgent(id: "a", tag: "first"),
            source: .firstParty
        )
        XCTAssertFalse(registered)
        let entry = await reg.entry(id: "a")
        XCTAssertEqual(entry?.source, .user)
        XCTAssertEqual((entry?.agent as? FakeAgent)?.tag, "user")
    }

    func testEqualPrecedenceLastWriterWins() async {
        let reg = AgentRegistry()
        await reg.register(FakeAgent(id: "a", tag: "first"), source: .user)
        await reg.register(FakeAgent(id: "a", tag: "second"), source: .user)
        let entry = await reg.entry(id: "a")
        XCTAssertEqual((entry?.agent as? FakeAgent)?.tag, "second")
    }

    func testAllEntriesReturnsAllRegisteredIds() async {
        let reg = AgentRegistry()
        await reg.register(FakeAgent(id: "a", tag: "a"), source: .firstParty)
        await reg.register(FakeAgent(id: "b", tag: "b"), source: .firstParty)
        let ids = await Set(reg.allEntries().map(\.agent.id))
        XCTAssertEqual(ids, ["a", "b"])
    }

    // MARK: loadUserPersonas

    private func writeJSON(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    func testLoadUserPersonasRegistersValidFilesAndReportsBadOnes() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("infer-agents-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Good persona.
        try writeJSON("""
        {
          "schemaVersion": 1,
          "id": "good",
          "metadata": {"name": "Good"},
          "systemPrompt": "ok"
        }
        """, to: tmp.appendingPathComponent("good.json"))

        // Bad persona: unsupported schema version.
        try writeJSON("""
        {
          "schemaVersion": 99,
          "id": "future",
          "metadata": {"name": "Future"},
          "systemPrompt": "x"
        }
        """, to: tmp.appendingPathComponent("future.json"))

        // Non-JSON file: should be ignored.
        try writeJSON("hello", to: tmp.appendingPathComponent("notes.txt"))

        let reg = AgentRegistry()
        let errors = await reg.loadUserPersonas(from: tmp)

        let entries = await reg.allEntries()
        XCTAssertEqual(entries.map(\.agent.id), ["good"])
        XCTAssertEqual(entries.first?.source, .user)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.url.lastPathComponent, "future.json")
    }

    func testLoadUserPersonasMissingDirectoryReturnsNoErrors() async {
        let reg = AgentRegistry()
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        let errors = await reg.loadUserPersonas(from: missing)
        XCTAssertTrue(errors.isEmpty)
        let entries = await reg.allEntries()
        XCTAssertTrue(entries.isEmpty)
    }
}
