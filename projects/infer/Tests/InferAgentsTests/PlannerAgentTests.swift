import XCTest
@testable import InferAgents

/// Drives `PlannerAgent.customLoop` with a scripted decoder so we
/// can assert plan / execute / replan / synthesise behaviour without
/// running a real LLM. The decoder pops responses in FIFO order;
/// running out raises a clear failure so over-eager planners surface
/// in the test rather than hang.
private actor ScriptedDecoder {
    private var responses: [String]
    private(set) var calls: [[TranscriptMessage]] = []

    init(_ responses: [String]) {
        self.responses = responses
    }

    func nextResponse(for messages: [TranscriptMessage]) -> String {
        calls.append(messages)
        guard !responses.isEmpty else {
            return "TEST_BUG: scripted decoder ran out of responses"
        }
        return responses.removeFirst()
    }

    func callCount() -> Int { calls.count }
    func lastMessages() -> [TranscriptMessage] { calls.last ?? [] }
}

private actor RecordingToolInvoker {
    var invocations: [(name: ToolName, arguments: String)] = []
    var failureForNextCalls: [String?] = []

    func append(_ name: ToolName, _ arguments: String) async -> ToolResult {
        invocations.append((name, arguments))
        let failure: String?
        if !failureForNextCalls.isEmpty {
            failure = failureForNextCalls.removeFirst()
        } else {
            failure = nil
        }
        if let failure {
            return ToolResult(output: "", error: failure)
        }
        return ToolResult(output: "ok-result-for-\(name)")
    }

    func setFailures(_ pattern: [String?]) {
        self.failureForNextCalls = pattern
    }
}

final class PlannerAgentTests: XCTestCase {

    private func makeAgent(config: PlannerAgent.Config = .init()) -> PlannerAgent {
        PlannerAgent(
            id: "test.planner",
            metadata: AgentMetadata(name: "Planner"),
            requirements: AgentRequirements(toolsAllow: ["t.echo"]),
            decodingParams: DecodingParams(temperature: 0, topP: 1, maxTokens: 64),
            plannerSystemPrompt: "You are a planner.",
            config: config
        )
    }

    private func makeContext(
        decoder: ScriptedDecoder,
        invoker: RecordingToolInvoker
    ) -> AgentContext {
        AgentContext(
            runner: RunnerHandle(
                backend: .llama,
                templateFamily: .llama3,
                maxContext: 4096,
                currentTokenCount: 0
            ),
            tools: ToolCatalog(tools: [
                ToolSpec(name: "t.echo", description: "echoes its args"),
            ]),
            transcript: [],
            stepCount: 0,
            invokeTool: { name, args in await invoker.append(name, args) },
            decode: { messages, _ in await decoder.nextResponse(for: messages) }
        )
    }

    // MARK: - Happy path

    func testPlanThenExecuteThenSynthesise() async throws {
        let decoder = ScriptedDecoder([
            // 1. Plan.
            "1. step alpha\n2. step beta",
            // 2. Step 1 execute (no tool call → text output).
            "alpha-result",
            // 3. Step 2 execute (no tool call → text output).
            "beta-result",
            // 4. Final synthesis.
            "Done: alpha + beta.",
        ])
        let invoker = RecordingToolInvoker()
        let agent = makeAgent()

        let trace = try await agent.customLoop(
            turn: AgentTurn(userText: "do the thing"),
            context: makeContext(decoder: decoder, invoker: invoker)
        )
        let unwrappedTrace = try XCTUnwrap(trace)
        if case .finalAnswer(let text) = unwrappedTrace.terminator {
            XCTAssertEqual(text, "Done: alpha + beta.")
        } else {
            XCTFail("expected .finalAnswer terminator, got \(String(describing: unwrappedTrace.terminator))")
        }
        // No tool calls should have fired in this script — both step
        // decodes returned bare text.
        let invs = await invoker.invocations
        XCTAssertEqual(invs.count, 0)
        let count = await decoder.callCount()
        XCTAssertEqual(count, 4)
    }

    // MARK: - Tool-driven step

    func testToolCallStepRecordsInvocationAndOutput() async throws {
        // Llama-3 family tool call syntax: <|python_tag|>{"name":...}<|eom_id|>
        let toolCall = #"<|python_tag|>{"name": "t.echo", "parameters": {"text": "hi"}}<|eom_id|>"#
        let decoder = ScriptedDecoder([
            "1. echo something",
            toolCall,
            "All done.",
        ])
        let invoker = RecordingToolInvoker()
        let agent = makeAgent()

        let trace = try await agent.customLoop(
            turn: AgentTurn(userText: "echo"),
            context: makeContext(decoder: decoder, invoker: invoker)
        )
        let unwrappedTrace = try XCTUnwrap(trace)
        // Trace should include the tool call + result pair plus the
        // final answer.
        let toolCalls = unwrappedTrace.steps.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        XCTAssertEqual(toolCalls.count, 1)
        let invs = await invoker.invocations
        XCTAssertEqual(invs.count, 1)
        XCTAssertEqual(invs.first?.name, "t.echo")
    }

    // MARK: - Replanning on failure

    func testReplansOnceWhenStepFails() async throws {
        let toolCall = #"<|python_tag|>{"name": "t.echo", "parameters": {"text": "x"}}<|eom_id|>"#
        let decoder = ScriptedDecoder([
            // 1. Plan with one step.
            "1. call the tool",
            // 2. Step 1 attempt: emits a tool call (which will fail).
            toolCall,
            // 3. Replan response: a fresh single-step plan.
            "1. take a different approach",
            // 4. New step 1 attempt: bare text (no tool call).
            "did the alternative",
            // 5. Synthesis.
            "Recovered after failure.",
        ])
        let invoker = RecordingToolInvoker()
        await invoker.setFailures([
            "tool exploded",
        ])
        let agent = makeAgent(config: .init(maxStepDecodes: 12, maxReplans: 1))

        let trace = try await agent.customLoop(
            turn: AgentTurn(userText: "fix it"),
            context: makeContext(decoder: decoder, invoker: invoker)
        )
        let unwrappedTrace = try XCTUnwrap(trace)
        if case .finalAnswer(let text) = unwrappedTrace.terminator {
            XCTAssertEqual(text, "Recovered after failure.")
        } else {
            XCTFail("expected .finalAnswer, got \(String(describing: unwrappedTrace.terminator))")
        }
        // The trace should mention "Plan revised" — the planner emits
        // an assistantText with that prefix when revise() succeeds.
        let revisedSteps = unwrappedTrace.steps.filter { step in
            if case .assistantText(let t) = step, t.contains("Plan revised") {
                return true
            }
            return false
        }
        XCTAssertEqual(revisedSteps.count, 1, "planner should emit exactly one revise event")
    }

    // MARK: - Budget exhaustion

    func testBudgetExceededHaltsAndEmitsTerminator() async throws {
        let decoder = ScriptedDecoder([
            // Plan: three steps, but the per-step budget allows only
            // two execution decodes total.
            "1. one\n2. two\n3. three",
            "out-1",
            "out-2",
        ])
        let invoker = RecordingToolInvoker()
        let agent = makeAgent(config: .init(maxStepDecodes: 2, maxReplans: 0))

        let trace = try await agent.customLoop(
            turn: AgentTurn(userText: "x"),
            context: makeContext(decoder: decoder, invoker: invoker)
        )
        let unwrappedTrace = try XCTUnwrap(trace)
        if case .budgetExceeded = unwrappedTrace.terminator {
            // expected
        } else {
            XCTFail("expected .budgetExceeded, got \(String(describing: unwrappedTrace.terminator))")
        }
    }

    // MARK: - Decoder missing

    func testThrowsWhenDecoderMissing() async {
        let agent = makeAgent()
        let ctxNoDecoder = AgentContext(
            runner: RunnerHandle(
                backend: .llama,
                templateFamily: .llama3,
                maxContext: 4096,
                currentTokenCount: 0
            ),
            tools: .empty
        )
        do {
            _ = try await agent.customLoop(
                turn: AgentTurn(userText: "x"),
                context: ctxNoDecoder
            )
            XCTFail("expected throw on missing decoder")
        } catch AgentError.decoderMissing {
            // expected
        } catch {
            XCTFail("expected decoderMissing, got \(error)")
        }
    }

    // MARK: - Plan parse fallback

    func testEmptyPlanFallsBackToSingleStepAtUserText() async throws {
        let decoder = ScriptedDecoder([
            // Plan: empty / unparseable.
            "",
            // Single-step execute.
            "did it",
            // Synthesis.
            "Final.",
        ])
        let invoker = RecordingToolInvoker()
        let agent = makeAgent()

        let trace = try await agent.customLoop(
            turn: AgentTurn(userText: "the goal"),
            context: makeContext(decoder: decoder, invoker: invoker)
        )
        let unwrappedTrace = try XCTUnwrap(trace)
        if case .finalAnswer(let text) = unwrappedTrace.terminator {
            XCTAssertEqual(text, "Final.")
        } else {
            XCTFail("expected .finalAnswer, got \(String(describing: unwrappedTrace.terminator))")
        }
    }
}
