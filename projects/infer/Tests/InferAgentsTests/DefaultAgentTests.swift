import XCTest
@testable import InferAgents
@testable import InferCore

final class DefaultAgentTests: XCTestCase {
    private var context: AgentContext {
        AgentContext(
            runner: RunnerHandle(
                backend: .llama,
                templateFamily: .llama3,
                maxContext: 8192,
                currentTokenCount: 0
            )
        )
    }

    func testIdIsStable() {
        XCTAssertEqual(DefaultAgent().id, DefaultAgent.id)
        XCTAssertEqual(DefaultAgent.id, "infer.default")
    }

    func testDerivesDecodingParamsFromSettings() {
        let settings = InferSettings(
            systemPrompt: "sys",
            temperature: 0.33,
            topP: 0.66,
            maxTokens: 256
        )
        let agent = DefaultAgent(settings: settings)
        let p = agent.decodingParams(for: context)
        XCTAssertEqual(p, DecodingParams(temperature: 0.33, topP: 0.66, maxTokens: 256))
    }

    func testSystemPromptReflectsSettings() async throws {
        let settings = InferSettings(
            systemPrompt: "you are helpful",
            temperature: 0.8,
            topP: 0.95,
            maxTokens: 512
        )
        let agent = DefaultAgent(settings: settings)
        let got = try await agent.systemPrompt(for: context)
        XCTAssertEqual(got, "you are helpful")
    }

    func testRequirementsAcceptAnyBackend() {
        XCTAssertEqual(DefaultAgent().requirements.backend, .any)
    }
}
