import XCTest
@testable import InferAgents

/// Minimal conformance to exercise the protocol's default hooks. Every
/// method not explicitly overridden here should come from the extension
/// in `Agent.swift`.
private struct StubAgent: Agent {
    let id: AgentID = "stub"
    let metadata = AgentMetadata(name: "Stub")
    var requirements = AgentRequirements()

    func decodingParams(for context: AgentContext) -> DecodingParams {
        DecodingParams(temperature: 0.5, topP: 1.0, maxTokens: 100)
    }

    func systemPrompt(for context: AgentContext) async throws -> String {
        "stub"
    }
}

final class AgentProtocolTests: XCTestCase {
    private func makeContext(tools: [ToolSpec] = []) -> AgentContext {
        AgentContext(
            runner: RunnerHandle(
                backend: .llama,
                templateFamily: .llama3,
                maxContext: 8192,
                currentTokenCount: 0
            ),
            tools: ToolCatalog(tools: tools)
        )
    }

    func testToolsAvailableDefaultEmptyAllowlistReturnsAll() async throws {
        let agent = StubAgent()
        let ctx = makeContext(tools: [
            ToolSpec(name: "a"),
            ToolSpec(name: "b"),
        ])
        let got = try await agent.toolsAvailable(for: ctx)
        XCTAssertEqual(Set(got.map(\.name)), ["a", "b"])
    }

    func testToolsAvailableDefaultAppliesAllowAndDeny() async throws {
        var agent = StubAgent()
        agent.requirements = AgentRequirements(toolsAllow: ["a", "b"], toolsDeny: ["b"])
        let ctx = makeContext(tools: [
            ToolSpec(name: "a"),
            ToolSpec(name: "b"),
            ToolSpec(name: "c"),
        ])
        let got = try await agent.toolsAvailable(for: ctx)
        XCTAssertEqual(got.map(\.name), ["a"])
    }

    func testTransformToolResultDefaultIsPassthrough() async throws {
        let agent = StubAgent()
        let call = ToolCall(name: "a", arguments: "{}")
        let result = ToolResult(output: "hi")
        let got = try await agent.transformToolResult(result, call: call, context: makeContext())
        XCTAssertEqual(got, result)
    }

    func testShouldContinueStopsOnFinalAnswer() async {
        let agent = StubAgent()
        let decision = await agent.shouldContinue(after: .finalAnswer("done"), context: makeContext())
        XCTAssertEqual(decision, .stop(reason: "finalAnswer"))
    }

    func testShouldContinueStopsOnCancelledAndBudget() async {
        let agent = StubAgent()
        let ctx = makeContext()
        let a = await agent.shouldContinue(after: .cancelled, context: ctx)
        XCTAssertEqual(a, .stop(reason: "cancelled"))
        let b = await agent.shouldContinue(after: .budgetExceeded, context: ctx)
        XCTAssertEqual(b, .stop(reason: "budgetExceeded"))
    }

    func testShouldContinueContinuesOnNonTerminalSteps() async {
        let agent = StubAgent()
        let ctx = makeContext()
        let a = await agent.shouldContinue(after: .assistantText("hi"), context: ctx)
        XCTAssertEqual(a, .continue)
        let b = await agent.shouldContinue(
            after: .toolCall(ToolCall(name: "x", arguments: "{}")),
            context: ctx
        )
        XCTAssertEqual(b, .continue)
    }

    func testCustomLoopDefaultIsNil() async throws {
        // Default behaviour: agents without a custom loop fall through
        // to the host's standard loop. Conformances that *do* want to
        // skip the LLM (deterministic / tool-only / external-service
        // agents) override this to return a non-nil StepTrace.
        let agent = StubAgent()
        let trace = try await agent.customLoop(
            turn: AgentTurn(userText: "hi"),
            context: makeContext()
        )
        XCTAssertNil(trace)
    }
}
