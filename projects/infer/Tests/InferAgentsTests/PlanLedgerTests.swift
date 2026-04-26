import XCTest
@testable import InferAgents

final class PlanLedgerTests: XCTestCase {

    // MARK: - PlanParser

    func testParserHandlesNumberedList() {
        let text = """
        1. Fetch the data
        2. Summarise it
        3. Reply to the user
        """
        let steps = PlanParser.parseSteps(from: text)
        XCTAssertEqual(steps, [
            "Fetch the data",
            "Summarise it",
            "Reply to the user",
        ])
    }

    func testParserHandlesParenthesisedNumbering() {
        let text = "1) one\n2) two"
        XCTAssertEqual(PlanParser.parseSteps(from: text), ["one", "two"])
    }

    func testParserHandlesBullets() {
        let text = "- alpha\n* beta\n• gamma"
        XCTAssertEqual(PlanParser.parseSteps(from: text), ["alpha", "beta", "gamma"])
    }

    func testParserDropsPreamble() {
        // No numbering at all → fallback path. First line ends with ":"
        // so it's classified as preamble and dropped.
        let text = """
        Here is the plan:
        Do step one
        Do step two
        """
        XCTAssertEqual(PlanParser.parseSteps(from: text), ["Do step one", "Do step two"])
    }

    func testParserMixedListIgnoresUnmarkedNoise() {
        // Once any marker is found, lines without markers are dropped
        // (assumed to be commentary).
        let text = """
        Sure, here's the plan:
        1. First
        2. Second
        """
        XCTAssertEqual(PlanParser.parseSteps(from: text), ["First", "Second"])
    }

    func testParserEmptyInputReturnsEmpty() {
        XCTAssertTrue(PlanParser.parseSteps(from: "").isEmpty)
        XCTAssertTrue(PlanParser.parseSteps(from: "   \n\n  ").isEmpty)
    }

    // MARK: - PlanLedger mutators

    func testCompleteAdvancesCursorAndRecordsOutput() {
        var ledger = PlanLedger(goal: "g", steps: [
            .init(ordinal: 1, description: "a"),
            .init(ordinal: 2, description: "b"),
        ])
        ledger.beginCurrentStep()
        XCTAssertEqual(ledger.steps[0].status, .running)
        ledger.completeCurrentStep(output: "result-a")
        XCTAssertEqual(ledger.cursor, 1)
        XCTAssertEqual(ledger.steps[0].status, .completed)
        XCTAssertEqual(ledger.steps[0].output, "result-a")
        XCTAssertFalse(ledger.isComplete)
    }

    func testFailAdvancesAndRecordsErrorMessage() {
        var ledger = PlanLedger(goal: "g", steps: [
            .init(ordinal: 1, description: "a"),
        ])
        ledger.failCurrentStep(errorMessage: "boom")
        XCTAssertEqual(ledger.steps[0].status, .failed)
        XCTAssertEqual(ledger.steps[0].errorMessage, "boom")
        XCTAssertTrue(ledger.isComplete)
        XCTAssertTrue(ledger.hasFailures)
    }

    func testReviseReplacesRemainingSteps() {
        var ledger = PlanLedger(goal: "g", steps: [
            .init(ordinal: 1, description: "a"),
            .init(ordinal: 2, description: "b"),
            .init(ordinal: 3, description: "c"),
        ])
        ledger.completeCurrentStep(output: "ok")
        // Cursor at 1; revise the remaining two.
        ledger.revise(remainingSteps: ["b-prime", "d", "e"])
        XCTAssertEqual(ledger.steps.count, 4)
        XCTAssertEqual(ledger.steps[0].description, "a")
        XCTAssertEqual(ledger.steps[0].status, .completed)
        XCTAssertEqual(ledger.steps[1].description, "b-prime")
        XCTAssertEqual(ledger.steps[1].ordinal, 2)
        XCTAssertEqual(ledger.steps[3].ordinal, 4)
        XCTAssertEqual(ledger.replanCount, 1)
        XCTAssertEqual(ledger.cursor, 1)  // cursor unchanged
    }

    func testReviseAtStartReplacesEverything() {
        var ledger = PlanLedger(goal: "g", steps: [
            .init(ordinal: 1, description: "a"),
        ])
        ledger.revise(remainingSteps: ["x", "y"])
        XCTAssertEqual(ledger.steps.map(\.description), ["x", "y"])
        XCTAssertEqual(ledger.steps.map(\.ordinal), [1, 2])
    }

    func testRenderForPromptIncludesGlyphs() {
        var ledger = PlanLedger(goal: "do thing", steps: [
            .init(ordinal: 1, description: "fetch"),
            .init(ordinal: 2, description: "summarise"),
        ])
        ledger.completeCurrentStep(output: "data")
        let rendered = ledger.renderForPrompt()
        XCTAssertTrue(rendered.contains("Goal: do thing"))
        XCTAssertTrue(rendered.contains("[x] 1. fetch"))
        XCTAssertTrue(rendered.contains("[ ] 2. summarise"))
        XCTAssertTrue(rendered.contains("output: data"))
    }

    func testLedgerRoundTripsThroughJSON() throws {
        var ledger = PlanLedger(goal: "g", steps: [
            .init(ordinal: 1, description: "a"),
            .init(ordinal: 2, description: "b"),
        ])
        ledger.completeCurrentStep(output: "ok")
        ledger.failCurrentStep(errorMessage: "boom")
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(PlanLedger.self, from: data)
        XCTAssertEqual(decoded, ledger)
    }
}
