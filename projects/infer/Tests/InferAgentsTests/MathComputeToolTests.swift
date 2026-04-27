import XCTest
@testable import InferAgents

final class MathComputeToolTests: XCTestCase {
    private let tool = MathComputeTool()

    private func eval(_ expression: String) async throws -> ToolResult {
        let payload: [String: Any] = ["expression": expression]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await tool.invoke(arguments: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Happy path

    func testIntegerArithmetic() async throws {
        let result = try await eval("2 + 3 * 4")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "14")
    }

    func testThePromptCanonicalCase() async throws {
        // 0.0825 * 12 * 30 — the example that motivated the tool.
        let result = try await eval("0.0825 * 12 * 30")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "29.7")
    }

    func testParens() async throws {
        let result = try await eval("(1 + 2) * (3 + 4)")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "21")
    }

    func testScientificNotation() async throws {
        let result = try await eval("1.5e3 + 500")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "2000")
    }

    func testNegativeNumbers() async throws {
        let result = try await eval("-5 + 3")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "-2")
    }

    func testIntegerResultPrintsWithoutTrailingPoint() async throws {
        let result = try await eval("100 / 4")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "25")
    }

    func testFloatResultPreservesPrecision() async throws {
        let result = try await eval("1 / 3")
        XCTAssertNil(result.error)
        XCTAssertTrue(result.output.hasPrefix("0.333"), "got \(result.output)")
    }

    // MARK: - Security: FUNCTION: rejection

    func testRejectsFunctionCall() async throws {
        // The whole reason for the whitelist guard. If this ever
        // returns success, the security gate is broken.
        let result = try await eval("FUNCTION('hello', 'uppercaseString')")
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("disallowed"))
    }

    func testRejectsAnyLetters() async throws {
        for expr in ["sqrt(4)", "log(10)", "abs(-3)", "PI"] {
            let result = try await eval(expr)
            XCTAssertEqual(result.output, "", "leaked through: \(expr)")
            XCTAssertNotNil(result.error, "no error for: \(expr)")
        }
    }

    // Verify the regex itself: `e` and `E` are allowed but only as
    // characters in the input — they pass the whitelist, then
    // NSExpression's syntax check is what rules on whether they're
    // valid scientific-notation markers in context.
    func testWhitelistRegexAcceptsScientificE() {
        let s = "1e3"
        let range = NSRange(s.startIndex..., in: s)
        XCTAssertNotNil(MathComputeTool.whitelistRegex.firstMatch(in: s, range: range))
    }

    func testWhitelistRegexRejectsLetters() {
        let s = "FUNCTION"
        let range = NSRange(s.startIndex..., in: s)
        XCTAssertNil(MathComputeTool.whitelistRegex.firstMatch(in: s, range: range))
    }

    // MARK: - Edge cases

    func testEmptyExpressionRejected() async throws {
        let result = try await eval("   ")
        XCTAssertNotNil(result.error)
    }

    func testOversizeExpressionRejected() async throws {
        let big = String(repeating: "1+", count: 200) + "1"
        let result = try await eval(big)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("exceeds"))
    }

    func testDivisionByZeroSurfacedAsError() async throws {
        // Bare-integer literals get coerced to doubles before
        // evaluation, so `1 / 0` becomes `1.0 / 0.0` → +inf, which
        // the tool's `isFinite` guard rejects.
        let result = try await eval("1 / 0")
        XCTAssertNotNil(result.error)
        if let err = result.error {
            XCTAssertTrue(err.contains("not finite"), "expected 'not finite' error, got: \(err)")
        }
    }

    func testIntegerDivisionDoesNotTruncate() async throws {
        // Without the integer-to-double coercion, NSExpression evaluates
        // this as integer division and returns 0 — the surprise this
        // tool exists to prevent.
        let result = try await eval("1 / 3")
        XCTAssertNil(result.error)
        XCTAssertTrue(result.output.hasPrefix("0.333"), "got \(result.output)")
    }

    func testMalformedJSONRejected() async throws {
        let result = try await tool.invoke(arguments: "not-json")
        XCTAssertNotNil(result.error)
    }
}
