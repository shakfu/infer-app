import XCTest
@testable import InferAgents
@testable import InferCore

/// Schema v2 (`docs/dev/agent_kinds.md`): `kind` discriminator,
/// `contextPath` markdown sidecar, forward-declared composition fields,
/// validation rules 1-6, runtime persona-tool emptiness.
final class AgentKindTests: XCTestCase {

    // MARK: - kind decoding / round-trip

    func testKindRoundTripsThroughEncodeDecode() throws {
        let agent = PromptAgent(
            id: "rt",
            kind: .agent,
            metadata: AgentMetadata(name: "RT"),
            requirements: AgentRequirements(toolsAllow: ["builtin.clock.now"]),
            systemPrompt: "p"
        )
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(PromptAgent.self, from: data)
        XCTAssertEqual(decoded.kind, .agent)
        XCTAssertEqual(decoded, agent)
    }

    func testV2RequiresExplicitKind() {
        let data = """
        {
          "schemaVersion": 2,
          "id": "x",
          "metadata": {"name": "X"},
          "systemPrompt": "p"
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data)) { error in
            guard case AgentError.invalidPersona(let msg) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(msg.contains("kind"), "message: \(msg)")
        }
    }

    // MARK: - validation rules (3): persona must not declare tools / composition

    func testPersonaWithToolsRejected() {
        let data = """
        {
          "schemaVersion": 2,
          "kind": "persona",
          "id": "x",
          "metadata": {"name": "X"},
          "requirements": {"toolsAllow": ["builtin.clock.now"]},
          "systemPrompt": "p"
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data)) { error in
            guard case AgentError.invalidPersona(let msg) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(msg.contains("persona declares tools"), "message: \(msg)")
        }
    }

    func testPersonaWithChainRejected() {
        let data = """
        {
          "schemaVersion": 2,
          "kind": "persona",
          "id": "x",
          "metadata": {"name": "X"},
          "systemPrompt": "p",
          "chain": ["other.agent"]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data)) { error in
            guard case AgentError.invalidPersona(let msg) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(msg.contains("composition"), "message: \(msg)")
        }
    }

    func testPersonaWithOrchestratorRejected() {
        let data = """
        {
          "schemaVersion": 2,
          "kind": "persona",
          "id": "x",
          "metadata": {"name": "X"},
          "systemPrompt": "p",
          "orchestrator": {"router": "r", "candidates": ["a"]}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data))
    }

    // MARK: - validation rules (4): empty agent loads (no error)

    func testEmptyAgentLoadsWithoutError() throws {
        let data = """
        {
          "schemaVersion": 2,
          "kind": "agent",
          "id": "empty",
          "metadata": {"name": "Empty"},
          "systemPrompt": "p"
        }
        """.data(using: .utf8)!
        let agent = try JSONDecoder().decode(PromptAgent.self, from: data)
        XCTAssertEqual(agent.kind, .agent)
        XCTAssertTrue(agent.requirements.toolsAllow.isEmpty)
    }

    // MARK: - v1 auto-classification

    func testV1WithToolsAutoClassifiedAsAgent() throws {
        let data = """
        {
          "schemaVersion": 1,
          "id": "x",
          "metadata": {"name": "X"},
          "requirements": {"toolsAllow": ["builtin.clock.now"]},
          "systemPrompt": "p"
        }
        """.data(using: .utf8)!
        let agent = try JSONDecoder().decode(PromptAgent.self, from: data)
        XCTAssertEqual(agent.kind, .agent)
    }

    func testV1WithoutToolsAutoClassifiedAsPersona() throws {
        let data = """
        {
          "schemaVersion": 1,
          "id": "x",
          "metadata": {"name": "X"},
          "systemPrompt": "p"
        }
        """.data(using: .utf8)!
        let agent = try JSONDecoder().decode(PromptAgent.self, from: data)
        XCTAssertEqual(agent.kind, .persona)
    }

    // MARK: - validation rules (5): structural composition checks

    func testEmptyChainEntryRejected() {
        let data = """
        {
          "schemaVersion": 2,
          "kind": "agent",
          "id": "x",
          "metadata": {"name": "X"},
          "systemPrompt": "p",
          "chain": ["a", ""]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data))
    }

    func testOrchestratorWithEmptyRouterRejected() {
        let data = """
        {
          "schemaVersion": 2,
          "kind": "agent",
          "id": "x",
          "metadata": {"name": "X"},
          "systemPrompt": "p",
          "orchestrator": {"router": "", "candidates": ["a"]}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data))
    }

    func testOrchestratorWithEmptyCandidatesRejected() {
        let data = """
        {
          "schemaVersion": 2,
          "kind": "agent",
          "id": "x",
          "metadata": {"name": "X"},
          "systemPrompt": "p",
          "orchestrator": {"router": "r", "candidates": []}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data))
    }

    // MARK: - contextPath

    func testContextPathConcatenatesSidecarOntoPrompt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sidecar = dir.appendingPathComponent("sidecar.md")
        try "Sidecar content.".write(to: sidecar, atomically: true, encoding: .utf8)

        let json = """
        {
          "schemaVersion": 2,
          "kind": "persona",
          "id": "p",
          "metadata": {"name": "P"},
          "systemPrompt": "Authored prompt.",
          "contextPath": "sidecar.md"
        }
        """.data(using: .utf8)!
        let jsonURL = dir.appendingPathComponent("p.json")
        try json.write(to: jsonURL)

        let agent = try AgentRegistry.decodePersona(at: jsonURL)
        XCTAssertEqual(agent.authoredSystemPrompt, "Authored prompt.")
        XCTAssertEqual(agent.contextPath, "sidecar.md")
        XCTAssertEqual(agent.promptText, "Authored prompt.\n\nSidecar content.")
    }

    func testContextPathMissingFileRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        {
          "schemaVersion": 2,
          "kind": "persona",
          "id": "p",
          "metadata": {"name": "P"},
          "systemPrompt": "p",
          "contextPath": "missing.md"
        }
        """.data(using: .utf8)!
        let jsonURL = dir.appendingPathComponent("p.json")
        try json.write(to: jsonURL)

        XCTAssertThrowsError(try AgentRegistry.decodePersona(at: jsonURL)) { error in
            guard case AgentError.invalidPersona(let msg) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(msg.contains("contextPath"), "message: \(msg)")
        }
    }

    func testContextPathTraversalRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        {
          "schemaVersion": 2,
          "kind": "persona",
          "id": "p",
          "metadata": {"name": "P"},
          "systemPrompt": "p",
          "contextPath": "../escape.md"
        }
        """.data(using: .utf8)!
        let jsonURL = dir.appendingPathComponent("p.json")
        try json.write(to: jsonURL)

        XCTAssertThrowsError(try AgentRegistry.decodePersona(at: jsonURL)) { error in
            guard case AgentError.invalidPersona(let msg) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(msg.contains("traverse"), "message: \(msg)")
        }
    }

    func testContextPathAbsolutePathRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        {
          "schemaVersion": 2,
          "kind": "persona",
          "id": "p",
          "metadata": {"name": "P"},
          "systemPrompt": "p",
          "contextPath": "/etc/passwd"
        }
        """.data(using: .utf8)!
        let jsonURL = dir.appendingPathComponent("p.json")
        try json.write(to: jsonURL)

        XCTAssertThrowsError(try AgentRegistry.decodePersona(at: jsonURL)) { error in
            guard case AgentError.invalidPersona(let msg) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(msg.contains("relative"), "message: \(msg)")
        }
    }

    func testContextPathWithoutSourceURLRejected() {
        // Plain `JSONDecoder().decode` from raw data has no
        // `personaSourceURL` in userInfo; contextPath must be rejected
        // because there's no anchor to resolve against.
        let data = """
        {
          "schemaVersion": 2,
          "kind": "persona",
          "id": "p",
          "metadata": {"name": "P"},
          "systemPrompt": "p",
          "contextPath": "sidecar.md"
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data))
    }

    // MARK: - runtime persona-tool emptiness

    func testPersonaToolsAvailableReturnsEmptyEvenIfRequirementsLeak() async throws {
        // Construct a persona via the in-memory init (bypasses the loader's
        // validation) and verify the runtime guarantee still holds.
        let agent = PromptAgent(
            id: "p",
            kind: .persona,
            metadata: AgentMetadata(name: "P"),
            requirements: AgentRequirements(toolsAllow: ["builtin.clock.now"]),
            systemPrompt: "p"
        )
        let ctx = AgentContext(
            runner: RunnerHandle(
                backend: .llama,
                templateFamily: .llama3,
                maxContext: 0,
                currentTokenCount: 0
            ),
            tools: ToolCatalog(tools: [
                ToolSpec(name: "builtin.clock.now", description: "now")
            ])
        )
        let exposed = try await agent.toolsAvailable(for: ctx)
        XCTAssertTrue(exposed.isEmpty)
    }

    func testAgentToolsAvailableHonoursAllow() async throws {
        let agent = PromptAgent(
            id: "a",
            kind: .agent,
            metadata: AgentMetadata(name: "A"),
            requirements: AgentRequirements(toolsAllow: ["builtin.clock.now"]),
            systemPrompt: "p"
        )
        let ctx = AgentContext(
            runner: RunnerHandle(
                backend: .llama,
                templateFamily: .llama3,
                maxContext: 0,
                currentTokenCount: 0
            ),
            tools: ToolCatalog(tools: [
                ToolSpec(name: "builtin.clock.now", description: "now"),
                ToolSpec(name: "builtin.text.wordcount", description: "wc"),
            ])
        )
        let exposed = try await agent.toolsAvailable(for: ctx)
        XCTAssertEqual(exposed.map(\.name), ["builtin.clock.now"])
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-kind-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
