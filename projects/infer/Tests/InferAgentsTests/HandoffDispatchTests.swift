import XCTest
@testable import InferAgents

final class HandoffDispatchTests: XCTestCase {

    func testParsesAgentsHandoffToolCallFromTrace() {
        let call = ToolCall(
            name: "agents.handoff",
            arguments: #"{"target": "writing.editor", "payload": "polish this"}"#
        )
        let trace = StepTrace(steps: [
            .toolCall(call),
            .toolResult(ToolResult(output: "handoff acknowledged")),
            .finalAnswer("done"),
        ])
        let outcome = AgentOutcome.completed(text: "done", trace: trace)

        let resolved = HandoffDispatch.parse(outcome: outcome)
        XCTAssertEqual(resolved?.target, "writing.editor")
        XCTAssertEqual(resolved?.payload, "polish this")
    }

    func testTolerantKeyNames() {
        // Models drift; accept agentID + input + message in addition
        // to the canonical target / payload keys.
        let call = ToolCall(
            name: "agents.handoff",
            arguments: #"{"agentID": "peer", "input": "do the thing"}"#
        )
        let trace = StepTrace(steps: [.toolCall(call), .finalAnswer("")])
        let outcome = AgentOutcome.completed(text: "", trace: trace)

        let resolved = HandoffDispatch.parse(outcome: outcome)
        XCTAssertEqual(resolved?.target, "peer")
        XCTAssertEqual(resolved?.payload, "do the thing")
    }

    func testIgnoresNonHandoffToolCalls() {
        let trace = StepTrace(steps: [
            .toolCall(ToolCall(name: "clock.now", arguments: "{}")),
            .finalAnswer("12:00"),
        ])
        let outcome = AgentOutcome.completed(text: "12:00", trace: trace)

        XCTAssertNil(HandoffDispatch.parse(outcome: outcome))
    }

    func testEmptyTargetReturnsNil() {
        let call = ToolCall(
            name: "agents.handoff",
            arguments: #"{"target": "", "payload": "x"}"#
        )
        let trace = StepTrace(steps: [.toolCall(call), .finalAnswer("")])
        let outcome = AgentOutcome.completed(text: "", trace: trace)

        XCTAssertNil(HandoffDispatch.parse(outcome: outcome))
    }

    func testFallbackToVisibleTextQwenSyntax() {
        // No tool call in trace; the raw <tool_call> survived in the
        // visible body. Parser should still extract it.
        let body = """
        Some preamble.
        <tool_call>
        {"name": "agents.handoff", "arguments": {"target": "peer", "payload": "go"}}
        </tool_call>
        """
        let trace = StepTrace(steps: [.finalAnswer(body)])
        let outcome = AgentOutcome.completed(text: body, trace: trace)

        let resolved = HandoffDispatch.parse(outcome: outcome)
        XCTAssertEqual(resolved?.target, "peer")
        XCTAssertEqual(resolved?.payload, "go")
    }

    func testFallbackToVisibleTextLlama3Syntax() {
        let body = """
        <|python_tag|>{"name": "agents.handoff", "parameters": {"target": "peer", "payload": "go"}}<|eom_id|>
        """
        let trace = StepTrace(steps: [.finalAnswer(body)])
        let outcome = AgentOutcome.completed(text: body, trace: trace)

        let resolved = HandoffDispatch.parse(outcome: outcome)
        XCTAssertEqual(resolved?.target, "peer")
        XCTAssertEqual(resolved?.payload, "go")
    }

    func testWrongToolNameInVisibleTextRejected() {
        let body = #"<tool_call>{"name": "agents.invoke", "arguments": {"target": "peer", "payload": "go"}}</tool_call>"#
        XCTAssertNil(HandoffDispatch.parse(text: body))
    }

    func testAgentsHandoffToolIsInert() async throws {
        let tool = AgentsHandoffTool()
        let result = try await tool.invoke(arguments: #"{"target":"x","payload":"y"}"#)
        XCTAssertNil(result.error)
        XCTAssertFalse(result.output.isEmpty, "ack output is fed back to the model so it can close the turn")
    }
}
