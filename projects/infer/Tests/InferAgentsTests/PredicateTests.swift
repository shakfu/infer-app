import XCTest
@testable import InferAgents

/// M5b (`docs/dev/agent_implementation_plan.md`): `Predicate` type
/// covering the five cases `agent_composition.md` specifies. Pure
/// data — no I/O, no side effects.
final class PredicateTests: XCTestCase {

    // MARK: - regex

    func testRegexMatchesAssistantText() {
        let outcome = AgentOutcome.completed(
            text: "Looks good to me.",
            trace: StepTrace.finalAnswer("Looks good to me.")
        )
        let p = Predicate.regex(pattern: "(?i)looks good")
        XCTAssertTrue(p.evaluate(outcome: outcome, remainingBudget: 5))
    }

    func testRegexNoMatchReturnsFalse() {
        let outcome = AgentOutcome.completed(text: "needs work", trace: StepTrace())
        XCTAssertFalse(Predicate.regex(pattern: "looks good").evaluate(outcome: outcome, remainingBudget: 5))
    }

    func testInvalidRegexEvaluatesFalse() {
        // "[" is an unterminated character class — invalid pattern.
        // Predicate should swallow rather than crash composition.
        let outcome = AgentOutcome.completed(text: "x", trace: StepTrace())
        XCTAssertFalse(Predicate.regex(pattern: "[").evaluate(outcome: outcome, remainingBudget: 5))
    }

    // MARK: - jsonShape

    func testJsonShapeAllKeysPresent() {
        let outcome = AgentOutcome.completed(
            text: #"{"verdict": "approve", "confidence": 0.9}"#,
            trace: StepTrace()
        )
        let p = Predicate.jsonShape(requiredKeys: ["verdict", "confidence"])
        XCTAssertTrue(p.evaluate(outcome: outcome, remainingBudget: 5))
    }

    func testJsonShapeMissingKey() {
        let outcome = AgentOutcome.completed(
            text: #"{"verdict": "approve"}"#,
            trace: StepTrace()
        )
        let p = Predicate.jsonShape(requiredKeys: ["verdict", "confidence"])
        XCTAssertFalse(p.evaluate(outcome: outcome, remainingBudget: 5))
    }

    func testJsonShapeNonJsonText() {
        let outcome = AgentOutcome.completed(text: "not json", trace: StepTrace())
        let p = Predicate.jsonShape(requiredKeys: ["x"])
        XCTAssertFalse(p.evaluate(outcome: outcome, remainingBudget: 5))
    }

    // MARK: - toolCalled / noToolCalls

    func testToolCalledTrue() {
        let trace = StepTrace(steps: [
            .toolCall(ToolCall(name: "builtin.clock.now", arguments: "{}")),
            .finalAnswer("now")
        ])
        let outcome = AgentOutcome.completed(text: "now", trace: trace)
        XCTAssertTrue(Predicate.toolCalled(name: "builtin.clock.now").evaluate(outcome: outcome, remainingBudget: 5))
    }

    func testToolCalledFalseWhenDifferentTool() {
        let trace = StepTrace(steps: [
            .toolCall(ToolCall(name: "builtin.text.wordcount", arguments: "{}")),
        ])
        let outcome = AgentOutcome.completed(text: "x", trace: trace)
        XCTAssertFalse(Predicate.toolCalled(name: "builtin.clock.now").evaluate(outcome: outcome, remainingBudget: 5))
    }

    func testNoToolCalls() {
        let outcome = AgentOutcome.completed(text: "x", trace: StepTrace.finalAnswer("x"))
        XCTAssertTrue(Predicate.noToolCalls.evaluate(outcome: outcome, remainingBudget: 5))
    }

    func testNoToolCallsFalseWhenToolWasCalled() {
        let trace = StepTrace(steps: [
            .toolCall(ToolCall(name: "x", arguments: "{}"))
        ])
        let outcome = AgentOutcome.completed(text: "y", trace: trace)
        XCTAssertFalse(Predicate.noToolCalls.evaluate(outcome: outcome, remainingBudget: 5))
    }

    // MARK: - stepBudgetExceeded

    func testStepBudgetExceededWhenZero() {
        let outcome = AgentOutcome.completed(text: "x", trace: StepTrace())
        XCTAssertTrue(Predicate.stepBudgetExceeded.evaluate(outcome: outcome, remainingBudget: 0))
    }

    func testStepBudgetNotExceededWhenPositive() {
        let outcome = AgentOutcome.completed(text: "x", trace: StepTrace())
        XCTAssertFalse(Predicate.stepBudgetExceeded.evaluate(outcome: outcome, remainingBudget: 3))
    }

    // MARK: - Codable

    func testCodableRoundTripRegex() throws {
        let p = Predicate.regex(pattern: "^hello$")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Predicate.self, from: data)
        XCTAssertEqual(decoded, p)
    }

    func testCodableRoundTripJsonShape() throws {
        let p = Predicate.jsonShape(requiredKeys: ["a", "b"])
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Predicate.self, from: data), p)
    }

    func testCodableRoundTripToolCalled() throws {
        let p = Predicate.toolCalled(name: "tool.x")
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Predicate.self, from: data), p)
    }

    func testCodableRoundTripBareCases() throws {
        for p in [Predicate.noToolCalls, .stepBudgetExceeded] {
            let data = try JSONEncoder().encode(p)
            XCTAssertEqual(try JSONDecoder().decode(Predicate.self, from: data), p)
        }
    }
}
