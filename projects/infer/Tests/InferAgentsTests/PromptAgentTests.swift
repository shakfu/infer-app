import XCTest
@testable import InferAgents
@testable import InferCore

final class PromptAgentTests: XCTestCase {
    private func minimalJSON(
        schemaVersion: Int = PromptAgent.currentSchemaVersion,
        id: String = "code-reviewer",
        name: String = "Code reviewer",
        prompt: String = "You are a meticulous code reviewer.",
        kind: String? = "persona"
    ) -> Data {
        let kindLine = kind.map { "\"kind\": \"\($0)\"," } ?? ""
        return """
        {
          "schemaVersion": \(schemaVersion),
          \(kindLine)
          "id": "\(id)",
          "metadata": {
            "name": "\(name)",
            "description": "Reviews diffs.",
            "author": "first-party"
          },
          "systemPrompt": "\(prompt)"
        }
        """.data(using: .utf8)!
    }

    func testDecodeMinimalFillsDefaults() throws {
        let data = minimalJSON()
        let agent = try JSONDecoder().decode(PromptAgent.self, from: data)
        XCTAssertEqual(agent.id, "code-reviewer")
        XCTAssertEqual(agent.metadata.name, "Code reviewer")
        XCTAssertEqual(agent.promptText, "You are a meticulous code reviewer.")
        // Default requirements and decoding params backfilled.
        XCTAssertEqual(agent.requirements.backend, .any)
        XCTAssertEqual(agent.defaultDecodingParams, DecodingParams(from: .defaults))
    }

    func testRoundTripPreservesFields() throws {
        let original = PromptAgent(
            id: "rt",
            kind: .agent,
            metadata: AgentMetadata(name: "RT", description: "round-trip"),
            requirements: AgentRequirements(
                backend: .llama,
                templateFamily: .llama3,
                minContext: 8192,
                toolsAllow: ["builtin.clock.now"]
            ),
            decodingParams: DecodingParams(temperature: 0.2, topP: 0.9, maxTokens: 2048),
            systemPrompt: "hello"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PromptAgent.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testUnknownSchemaVersionRejected() {
        let data = minimalJSON(schemaVersion: 99)
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data)) { error in
            guard case AgentError.unsupportedSchemaVersion(let v) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(v, 99)
        }
    }

    func testEmptyIdRejected() {
        let data = minimalJSON(id: "")
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data)) { error in
            guard case AgentError.invalidPersona = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testEmptyNameRejected() {
        let data = minimalJSON(name: "")
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data)) { error in
            guard case AgentError.invalidPersona = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testMissingRequiredFieldRejected() {
        let data = """
        {
          "schemaVersion": 1,
          "id": "x",
          "metadata": {"name": "X"}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data))
    }

    func testUnknownFieldsIgnoredInKnownVersion() throws {
        let data = """
        {
          "schemaVersion": 1,
          "id": "x",
          "metadata": {"name": "X"},
          "systemPrompt": "p",
          "futureField": {"whatever": true}
        }
        """.data(using: .utf8)!
        // Should decode cleanly; unknown keys are ignored by default.
        let agent = try JSONDecoder().decode(PromptAgent.self, from: data)
        XCTAssertEqual(agent.id, "x")
    }

    func testSystemPromptHookReturnsStoredText() async throws {
        let agent = PromptAgent(
            id: "p",
            metadata: AgentMetadata(name: "P"),
            systemPrompt: "the-prompt"
        )
        let ctx = AgentContext(
            runner: RunnerHandle(backend: .llama, templateFamily: .llama3, maxContext: 0, currentTokenCount: 0)
        )
        let got = try await agent.systemPrompt(for: ctx)
        XCTAssertEqual(got, "the-prompt")
    }
}
