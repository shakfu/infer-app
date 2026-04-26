import XCTest
@testable import InferAgents
@testable import InferCore

/// Unit tests for `DeterministicPipelineAgent` — Agent conformance
/// that runs a fixed sequence of tool calls with no LLM decoding.
/// Validates: bag binding across steps, output composition, error
/// short-circuit, missing-invoker hard error.
final class DeterministicPipelineAgentTests: XCTestCase {

    private func makeContext(invokeTool: ToolInvoker?) -> AgentContext {
        AgentContext(
            runner: RunnerHandle(
                backend: .any,
                templateFamily: nil,
                maxContext: 0,
                currentTokenCount: 0
            ),
            tools: ToolCatalog(tools: [
                ToolSpec(name: "fetch", description: "fetch"),
                ToolSpec(name: "transform", description: "transform"),
            ]),
            invokeTool: invokeTool
        )
    }

    func testTwoStepPipelineThreadsOutputThroughBag() async throws {
        // Two steps with simple plain-text I/O so the assertions stay
        // focused on bag plumbing and dispatch order — JSON-in-JSON
        // quoting is a tool-author concern, not a pipeline concern.
        // Step 1 (fetch): args echo the user input; result bound as
        //   "raw".
        // Step 2 (transform): args reference the bag's "raw"; result
        //   bound as "processed".
        // Output: returns "processed" verbatim.
        let agent = DeterministicPipelineAgent(
            id: "deterministic.demo",
            metadata: AgentMetadata(name: "Demo"),
            toolsAllow: ["fetch", "transform"],
            steps: [
                .init(
                    name: "fetch",
                    arguments: { user, _ in user },
                    bind: "raw"
                ),
                .init(
                    name: "transform",
                    arguments: { _, bag in bag["raw"] ?? "" },
                    bind: "processed"
                ),
            ],
            output: { _, bag in bag["processed"] ?? "" }
        )

        let invoker: ToolInvoker = { name, args in
            switch name {
            case "fetch": return ToolResult(output: "fetched(\(args))")
            case "transform": return ToolResult(output: "transformed(\(args))")
            default: return ToolResult(output: "", error: "unknown")
            }
        }

        let trace = try await agent.customLoop(
            turn: AgentTurn(userText: "topic"),
            context: makeContext(invokeTool: invoker)
        )
        XCTAssertNotNil(trace)
        guard let trace else { return }

        // Two (toolCall, toolResult) pairs + final answer.
        XCTAssertEqual(trace.steps.count, 5)
        guard case .toolCall(let c1) = trace.steps[0] else {
            return XCTFail("expected first step toolCall")
        }
        XCTAssertEqual(c1.name, "fetch")
        XCTAssertEqual(c1.arguments, "topic")
        XCTAssertEqual(trace.steps[1], .toolResult(ToolResult(output: "fetched(topic)")))

        guard case .toolCall(let c2) = trace.steps[2] else {
            return XCTFail("expected third step toolCall")
        }
        XCTAssertEqual(c2.name, "transform")
        // Bag substitution: transform sees the fetch step's output.
        XCTAssertEqual(c2.arguments, "fetched(topic)")

        XCTAssertEqual(
            trace.steps.last,
            .finalAnswer("transformed(fetched(topic))")
        )
    }

    func testToolErrorShortCircuitsRemainingSteps() async throws {
        // Step 1 returns an error; step 2 must NOT be invoked. Trace
        // ends with an `.error` terminator the composition layer can
        // route into a fallback.
        let invokeLog = ToolInvocationLog()
        let invoker: ToolInvoker = { name, args in
            await invokeLog.append(name: name, arguments: args)
            if name == "fetch" {
                return ToolResult(output: "", error: "404")
            }
            return ToolResult(output: "should not see this")
        }
        let agent = DeterministicPipelineAgent(
            id: "deterministic.fail",
            metadata: AgentMetadata(name: "Fail"),
            toolsAllow: ["fetch", "transform"],
            steps: [
                .fixed(name: "fetch", arguments: "{}", bind: "raw"),
                .fixed(name: "transform", arguments: "{}", bind: "out"),
            ],
            output: { _, bag in bag["out"] ?? "<missing>" }
        )
        let trace = try await agent.customLoop(
            turn: AgentTurn(userText: "x"),
            context: makeContext(invokeTool: invoker)
        )!
        // Exactly one tool was actually invoked.
        let invocations = await invokeLog.count
        XCTAssertEqual(invocations, 1)
        // Trace terminates on error.
        if case .error(let msg) = trace.steps.last {
            XCTAssertTrue(msg.contains("fetch"))
            XCTAssertTrue(msg.contains("404"))
        } else {
            XCTFail("expected .error terminator, got \(String(describing: trace.steps.last))")
        }
    }

    func testMissingInvokerThrowsHardError() async {
        let agent = DeterministicPipelineAgent(
            id: "deterministic.no-invoker",
            metadata: AgentMetadata(name: "X"),
            toolsAllow: ["fetch"],
            steps: [.fixed(name: "fetch", arguments: "{}", bind: nil)],
            output: { _, _ in "" }
        )
        do {
            _ = try await agent.customLoop(
                turn: AgentTurn(userText: "x"),
                context: makeContext(invokeTool: nil)
            )
            XCTFail("expected throw")
        } catch let error as AgentError {
            XCTAssertEqual(error, .toolInvokerMissing)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
