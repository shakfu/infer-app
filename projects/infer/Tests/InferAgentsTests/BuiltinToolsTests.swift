import XCTest
@testable import InferAgents

final class BuiltinToolsTests: XCTestCase {
    // MARK: ClockNowTool

    func testClockReturnsIsoString() async throws {
        // Pinned date => deterministic output.
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        let tool = ClockNowTool(fixedDate: pinned)
        let result = try await tool.invoke(arguments: "{}")
        XCTAssertEqual(result.error, nil)
        XCTAssertEqual(result.output, "2023-11-14T22:13:20Z")
    }

    func testClockIgnoresArguments() async throws {
        let tool = ClockNowTool(fixedDate: Date(timeIntervalSince1970: 0))
        // Tool says "call with {}", but a free-form arg shouldn't crash.
        let result = try await tool.invoke(arguments: "anything at all")
        XCTAssertNil(result.error)
        XCTAssertFalse(result.output.isEmpty)
    }

    func testClockSpecHasUsefulDescription() {
        let tool = ClockNowTool()
        XCTAssertFalse(tool.spec.description.isEmpty)
        XCTAssertEqual(tool.spec.name, "builtin.clock.now")
    }

    // MARK: WordCountTool

    func testWordCountBasic() async throws {
        let tool = WordCountTool()
        let result = try await tool.invoke(arguments: #"{"text": "hello world"}"#)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "2")
    }

    func testWordCountTrimsMultipleSpaces() async throws {
        let tool = WordCountTool()
        let result = try await tool.invoke(
            arguments: #"{"text": "  one   two\tthree\n\nfour  "}"#
        )
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "4")
    }

    func testWordCountEmptyString() async throws {
        let tool = WordCountTool()
        let result = try await tool.invoke(arguments: #"{"text": ""}"#)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "0")
    }

    func testWordCountMalformedArgumentsReturnsToolError() async throws {
        let tool = WordCountTool()
        let result = try await tool.invoke(arguments: "not json")
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
    }

    func testWordCountMissingTextKey() async throws {
        let tool = WordCountTool()
        let result = try await tool.invoke(arguments: #"{"other": "x"}"#)
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
    }

    // MARK: AgentsInvokeTool (M5c)

    func testAgentsInvokeNameAndSpec() {
        let tool = AgentsInvokeTool()
        XCTAssertEqual(tool.name, "agents.invoke")
        XCTAssertEqual(tool.spec.name, OrchestratorDispatch.invokeToolName)
        XCTAssertTrue(tool.spec.description.contains("agentID"))
    }

    func testAgentsInvokeReturnsAck() async throws {
        // The tool is inert — actual dispatch happens in
        // CompositionController.runOrchestrator after the segment
        // completes. Tool just returns an ack the runner can feed
        // back so the router closes its turn cleanly.
        let tool = AgentsInvokeTool()
        let result = try await tool.invoke(
            arguments: #"{"agentID":"x","input":"y"}"#
        )
        XCTAssertEqual(result.output, "dispatch acknowledged")
        XCTAssertNil(result.error)
    }

    func testAgentsInvokeAckRegardlessOfArgs() async throws {
        // Inert means inert — even malformed arguments produce an ack.
        // Validation of the dispatch payload happens downstream in
        // `OrchestratorDispatch.parse`.
        let tool = AgentsInvokeTool()
        let result = try await tool.invoke(arguments: "garbage")
        XCTAssertEqual(result.output, "dispatch acknowledged")
    }
}
