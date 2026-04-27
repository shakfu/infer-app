import XCTest
@testable import InferAgents
@testable import InferCore

/// Verifies that when `AgentContext.invokeToolStreaming` is wired,
/// `BasicLoop` surfaces intermediate `ToolEvent.log` events as
/// `AgentEvent.toolProgress` between `toolRunning` and `toolResulted`,
/// and that the final `ToolResult` still reaches the loop unchanged.
///
/// The streaming hook is preferred over `invokeTool` when both are
/// wired; a missing `invokeTool` no longer fails the loop as long as
/// the streaming hook is present.
final class BasicLoopStreamingToolTests: XCTestCase {

    private struct StubAgent: Agent {
        let id: AgentID = "stub"
        let metadata = AgentMetadata(name: "Stub")
        let requirements = AgentRequirements(toolsAllow: ["t.demo"])
        func decodingParams(for context: AgentContext) -> DecodingParams {
            DecodingParams(temperature: 0, topP: 1, maxTokens: 64)
        }
        func systemPrompt(for context: AgentContext) async throws -> String {
            "stub"
        }
    }

    private func makeContext(streaming: StreamingToolInvoker?) -> AgentContext {
        AgentContext(
            runner: RunnerHandle(
                backend: .llama,
                templateFamily: .llama3,
                maxContext: 4096,
                currentTokenCount: 0
            ),
            tools: ToolCatalog(tools: [ToolSpec(name: "t.demo", description: "demo")]),
            transcript: [],
            stepCount: 0,
            invokeTool: nil,
            invokeToolStreaming: streaming
        )
    }

    func testStreamingHookEmitsToolProgressEvents() async throws {
        // First decode produces a tool call; second decode is the final answer.
        let firstDecode = "<|python_tag|>{\"name\": \"t.demo\", \"parameters\": {}}<|eom_id|>"
        let runner = MockAgentRunner([firstDecode, "all done"])

        let invoker: StreamingToolInvoker = { _, _ in
            AsyncThrowingStream { c in
                c.yield(.log("step 1"))
                c.yield(.log("step 2"))
                c.yield(.result(ToolResult(output: "ok")))
                c.finish()
            }
        }

        let captured = EventBox()
        let trace = try await BasicLoop.run(
            agent: StubAgent(),
            turn: AgentTurn(userText: "go"),
            context: makeContext(streaming: invoker),
            runner: runner,
            events: { captured.append($0) }
        )

        // Trace shape: assistantText (empty prefix elided) → toolCall → toolResult → finalAnswer.
        let kinds = trace.steps.map(stepKind)
        XCTAssertEqual(kinds, ["toolCall", "toolResult", "finalAnswer"])
        if case .toolResult(let r) = trace.steps[1] {
            XCTAssertEqual(r.output, "ok")
        } else {
            XCTFail("expected toolResult step")
        }

        // Event order: toolRequested → toolRunning → toolProgress("step 1") →
        // toolProgress("step 2") → toolResulted → terminated.
        let progressMessages = captured.events.compactMap { event -> String? in
            if case .toolProgress(_, let message) = event { return message }
            return nil
        }
        XCTAssertEqual(progressMessages, ["step 1", "step 2"])

        // toolProgress must come AFTER toolRunning and BEFORE toolResulted.
        let names = captured.events.map(eventName)
        let runningIdx = names.firstIndex(of: "toolRunning")
        let firstProgressIdx = names.firstIndex(of: "toolProgress")
        let resultedIdx = names.firstIndex(of: "toolResulted")
        XCTAssertNotNil(runningIdx)
        XCTAssertNotNil(firstProgressIdx)
        XCTAssertNotNil(resultedIdx)
        XCTAssertLessThan(runningIdx!, firstProgressIdx!)
        XCTAssertLessThan(firstProgressIdx!, resultedIdx!)
    }

    func testStreamingHookSatisfiesInvokerRequirement() async throws {
        // No `invokeTool`, only `invokeToolStreaming` → loop must not throw
        // `AgentError.toolInvokerMissing`.
        let firstDecode = "<|python_tag|>{\"name\": \"t.demo\", \"parameters\": {}}<|eom_id|>"
        let runner = MockAgentRunner([firstDecode, "fine"])
        let invoker: StreamingToolInvoker = { _, _ in
            AsyncThrowingStream { c in
                c.yield(.result(ToolResult(output: "ok")))
                c.finish()
            }
        }
        let trace = try await BasicLoop.run(
            agent: StubAgent(),
            turn: AgentTurn(userText: "go"),
            context: makeContext(streaming: invoker),
            runner: runner
        )
        XCTAssertEqual(trace.terminator, .finalAnswer("fine"))
    }

    // MARK: - Helpers

    /// Thread-safe sink for the event closure (the loop is async; the
    /// closure may fire on different executors).
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [AgentEvent] = []
        var events: [AgentEvent] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }
        func append(_ event: AgentEvent) {
            lock.lock(); _events.append(event); lock.unlock()
        }
    }

    private func stepKind(_ step: StepTrace.Step) -> String {
        switch step {
        case .assistantText: return "assistantText"
        case .toolCall: return "toolCall"
        case .toolResult: return "toolResult"
        case .finalAnswer: return "finalAnswer"
        case .cancelled: return "cancelled"
        case .budgetExceeded: return "budgetExceeded"
        case .error: return "error"
        }
    }

    private func eventName(_ event: AgentEvent) -> String {
        switch event {
        case .assistantChunk: return "assistantChunk"
        case .toolRequested: return "toolRequested"
        case .toolRunning: return "toolRunning"
        case .toolProgress: return "toolProgress"
        case .toolResulted: return "toolResulted"
        case .finalChunk: return "finalChunk"
        case .terminated: return "terminated"
        }
    }
}
