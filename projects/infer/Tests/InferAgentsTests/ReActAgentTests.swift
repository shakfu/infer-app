import XCTest
@testable import InferAgents
@testable import InferCore

final class ReActAgentTests: XCTestCase {
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
        XCTAssertEqual(ReActAgent().id, ReActAgent.id)
        XCTAssertEqual(ReActAgent.id, "infer.react")
    }

    func testSystemPromptIncludesRubricAndUserPrompt() async throws {
        let settings = InferSettings(
            systemPrompt: "you are helpful",
            temperature: 0.7,
            topP: 0.9,
            maxTokens: 512
        )
        let agent = ReActAgent(settings: settings)
        let prompt = try await agent.systemPrompt(for: context)
        XCTAssertTrue(prompt.contains("you are helpful"))
        XCTAssertTrue(prompt.contains("Thought:"))
        XCTAssertTrue(prompt.contains("Final Answer:"))
        XCTAssertTrue(prompt.contains("Observation:"))
    }

    func testSystemPromptOmitsBlankBase() async throws {
        let settings = InferSettings(
            systemPrompt: "   ",
            temperature: 0.7,
            topP: 0.9,
            maxTokens: 512
        )
        let agent = ReActAgent(settings: settings)
        let prompt = try await agent.systemPrompt(for: context)
        XCTAssertFalse(prompt.hasPrefix(" "))
        XCTAssertFalse(prompt.hasPrefix("\n"))
        XCTAssertTrue(prompt.contains("Thought:"))
    }

    func testTransformToolResultWrapsAsObservation() async throws {
        let agent = ReActAgent()
        let raw = ToolResult(output: "42")
        let wrapped = try await agent.transformToolResult(
            raw,
            call: ToolCall(name: "calc", arguments: "{}"),
            context: context
        )
        XCTAssertEqual(wrapped.output, "Observation: 42")
        XCTAssertNil(wrapped.error)
    }

    func testTransformToolResultWrapsErrorMessage() async throws {
        let agent = ReActAgent()
        let raw = ToolResult(output: "", error: "tool exploded")
        let wrapped = try await agent.transformToolResult(
            raw,
            call: ToolCall(name: "calc", arguments: "{}"),
            context: context
        )
        XCTAssertEqual(wrapped.output, "Observation: error: tool exploded")
        XCTAssertEqual(wrapped.error, "tool exploded")
    }

    func testShouldContinueStopsOnFinalAnswerInAssistantText() async {
        let agent = ReActAgent()
        let decision = await agent.shouldContinue(
            after: .assistantText("Thought: ok\nFinal Answer: 42"),
            context: context
        )
        XCTAssertEqual(decision, .stop(reason: "finalAnswer"))
    }

    func testShouldContinueContinuesOnPlainAssistantText() async {
        let agent = ReActAgent()
        let decision = await agent.shouldContinue(
            after: .assistantText("Thought: I should call a tool"),
            context: context
        )
        XCTAssertEqual(decision, .continue)
    }

    func testShouldContinueContinuesAfterToolResult() async {
        let agent = ReActAgent()
        let result = ToolResult(output: "Observation: 42")
        let decision = await agent.shouldContinue(
            after: .toolResult(result),
            context: context
        )
        XCTAssertEqual(decision, .continue)
    }

    func testShouldContinueStopsOnTerminators() async {
        let agent = ReActAgent()
        let cancelled = await agent.shouldContinue(after: .cancelled, context: context)
        XCTAssertEqual(cancelled, .stop(reason: "cancelled"))
        let budget = await agent.shouldContinue(after: .budgetExceeded, context: context)
        XCTAssertEqual(budget, .stop(reason: "budgetExceeded"))
        let final = await agent.shouldContinue(after: .finalAnswer("done"), context: context)
        XCTAssertEqual(final, .stop(reason: "finalAnswer"))
    }

    func testRequirementsAcceptAnyBackend() {
        XCTAssertEqual(ReActAgent().requirements.backend, .any)
    }

    func testDecodingParamsTrackSettings() {
        let settings = InferSettings(
            systemPrompt: "x",
            temperature: 0.42,
            topP: 0.84,
            maxTokens: 321
        )
        let agent = ReActAgent(settings: settings)
        let p = agent.decodingParams(for: context)
        XCTAssertEqual(p, DecodingParams(temperature: 0.42, topP: 0.84, maxTokens: 321))
    }
}
