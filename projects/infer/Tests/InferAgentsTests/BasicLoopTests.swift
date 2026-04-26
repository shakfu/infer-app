import XCTest
@testable import InferAgents
@testable import InferCore

/// Unit tests for `BasicLoop` — the runner-agnostic loop driver that
/// lives in `InferAgents` (parallel to the chat-view-model loop in the
/// host app). Validates the three turn shapes:
///
/// 1. Custom-loop short-circuit (no LLM decode).
/// 2. Single-decode (no tool call → `finalAnswer`).
/// 3. One-tool-call cycle (decode → tool → re-decode → `finalAnswer`).
///
/// Plus: budget exhaustion, cancellation, and event emission shape.
final class BasicLoopTests: XCTestCase {

    // Minimal Agent conformance for tests where we only care about
    // surface behaviour. Real conformances (`PromptAgent`,
    // `DeterministicPipelineAgent`) get their own targeted tests.
    private struct StubAgent: Agent {
        let id: AgentID = "stub"
        let metadata = AgentMetadata(name: "Stub")
        let requirements = AgentRequirements(toolsAllow: ["t.echo"])
        let prompt: String
        init(prompt: String = "you are a stub") { self.prompt = prompt }
        func decodingParams(for context: AgentContext) -> DecodingParams {
            DecodingParams(temperature: 0, topP: 1, maxTokens: 64)
        }
        func systemPrompt(for context: AgentContext) async throws -> String {
            prompt
        }
    }

    private func makeContext(
        invokeTool: ToolInvoker? = nil
    ) -> AgentContext {
        AgentContext(
            runner: RunnerHandle(
                backend: .llama,
                templateFamily: .llama3,
                maxContext: 4096,
                currentTokenCount: 0
            ),
            tools: ToolCatalog(tools: [
                ToolSpec(name: "t.echo", description: "echo")
            ]),
            transcript: [],
            stepCount: 0,
            invokeTool: invokeTool
        )
    }

    // MARK: - Single-decode (no tool call)

    func testSingleDecodeProducesFinalAnswer() async throws {
        let runner = MockAgentRunner(["the model's reply"])
        let trace = try await BasicLoop.run(
            agent: StubAgent(),
            turn: AgentTurn(userText: "hello"),
            context: makeContext(),
            runner: runner
        )
        XCTAssertEqual(trace.steps, [StepTrace.Step.finalAnswer("the model's reply")])
        // The mock saw one call and was handed the system + user pair.
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].first?.role, .system)
        XCTAssertEqual(runner.calls[0].last?.content, "hello")
    }

    func testStreamedChunksAreEmittedAsAssistantChunkEvents() async throws {
        let runner = MockAgentRunner([.init(["foo ", "bar ", "baz"])])
        var observed: [AgentEvent] = []
        let trace = try await BasicLoop.run(
            agent: StubAgent(),
            turn: AgentTurn(userText: "hi"),
            context: makeContext(),
            runner: runner,
            events: { observed.append($0) }
        )
        XCTAssertEqual(trace.steps, [StepTrace.Step.finalAnswer("foo bar baz")])
        // Three chunks + one terminator.
        let chunkCount = observed.filter {
            if case .assistantChunk = $0 { return true }
            return false
        }.count
        XCTAssertEqual(chunkCount, 3)
        XCTAssertEqual(observed.last, .terminated(.finalAnswer("foo bar baz")))
    }

    // MARK: - Tool call cycle

    func testOneToolCallCycleFeedsResultBackForSecondDecode() async throws {
        // First decode: emit a Llama-3 tool call. Second decode: emit
        // the user-facing answer. The loop must (a) parse the call,
        // (b) invoke the tool, (c) feed the result into the
        // transcript, (d) decode again.
        let firstDecode = "<|python_tag|>{\"name\": \"t.echo\", \"parameters\": {\"text\": \"hello\"}}<|eom_id|>"
        let secondDecode = "the answer using HELLO"
        let runner = MockAgentRunner([firstDecode, secondDecode])

        let invokeCalls = ToolInvocationLog()
        let invoker: ToolInvoker = { name, args in
            await invokeCalls.append(name: name, arguments: args)
            return ToolResult(output: "HELLO")
        }

        let trace = try await BasicLoop.run(
            agent: StubAgent(),
            turn: AgentTurn(userText: "say hello"),
            context: makeContext(invokeTool: invoker),
            runner: runner
        )

        // Trace: toolCall, toolResult, finalAnswer.
        XCTAssertEqual(trace.steps.count, 3)
        guard case .toolCall(let call) = trace.steps[0] else {
            return XCTFail("expected tool call first; got \(trace.steps[0])")
        }
        XCTAssertEqual(call.name, "t.echo")
        XCTAssertEqual(trace.steps[1], .toolResult(ToolResult(output: "HELLO")))
        XCTAssertEqual(trace.steps[2], .finalAnswer("the answer using HELLO"))

        // Two decodes: first against just user, second with the tool
        // round-trip appended.
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls[1].last?.role, .tool)
        XCTAssertEqual(runner.calls[1].last?.content, "HELLO")

        // One tool invocation, with the parsed args.
        let log = await invokeCalls.snapshot()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].name, "t.echo")
    }

    func testToolCallWithoutInvokerThrows() async {
        let firstDecode = "<|python_tag|>{\"name\": \"t.echo\", \"parameters\": {}}<|eom_id|>"
        let runner = MockAgentRunner([firstDecode])
        do {
            _ = try await BasicLoop.run(
                agent: StubAgent(),
                turn: AgentTurn(userText: "x"),
                context: makeContext(invokeTool: nil),
                runner: runner
            )
            XCTFail("expected throw")
        } catch let error as AgentError {
            XCTAssertEqual(error, .toolInvokerMissing)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Custom loop short-circuit

    func testCustomLoopBypassesRunner() async throws {
        struct CustomAgent: Agent {
            let id: AgentID = "custom"
            let metadata = AgentMetadata(name: "Custom")
            let requirements = AgentRequirements()
            func decodingParams(for context: AgentContext) -> DecodingParams {
                DecodingParams(temperature: 0, topP: 1, maxTokens: 0)
            }
            func systemPrompt(for context: AgentContext) async throws -> String { "" }
            func customLoop(
                turn: AgentTurn,
                context: AgentContext
            ) async throws -> StepTrace? {
                StepTrace(steps: [.finalAnswer("from custom loop: \(turn.userText)")])
            }
        }
        let runner = MockAgentRunner([] as [String])
        let trace = try await BasicLoop.run(
            agent: CustomAgent(),
            turn: AgentTurn(userText: "ping"),
            context: makeContext(),
            runner: runner
        )
        XCTAssertEqual(trace.steps, [StepTrace.Step.finalAnswer("from custom loop: ping")])
        // Runner was never consulted.
        XCTAssertEqual(runner.calls.count, 0)
    }

    // MARK: - Budget

    func testBudgetExhaustionEmitsBudgetExceeded() async throws {
        // Force the loop to keep cycling tool calls forever (each
        // decode is a tool call, never a final answer) until the
        // budget runs out.
        let toolCall = "<|python_tag|>{\"name\": \"t.echo\", \"parameters\": {}}<|eom_id|>"
        let runner = MockAgentRunner(Array(repeating: toolCall, count: 10))
        let invoker: ToolInvoker = { _, _ in ToolResult(output: "ok") }
        let trace = try await BasicLoop.run(
            agent: StubAgent(),
            turn: AgentTurn(userText: "x"),
            context: makeContext(invokeTool: invoker),
            runner: runner,
            config: BasicLoop.Config(stepBudget: 2)
        )
        XCTAssertEqual(trace.terminator, .budgetExceeded)
    }
}

/// Actor-backed log of tool invocations. Exists because `ToolInvoker`
/// is `@Sendable` and capturing a mutable reference type from a closure
/// requires explicit isolation.
actor ToolInvocationLog {
    private(set) var entries: [(name: ToolName, arguments: String)] = []
    func append(name: ToolName, arguments: String) {
        entries.append((name, arguments))
    }
    func snapshot() -> [(name: ToolName, arguments: String)] { entries }
    var count: Int { entries.count }
}
