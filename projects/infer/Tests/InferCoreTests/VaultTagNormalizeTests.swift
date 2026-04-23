import XCTest

// VaultStore lives in the app target, not InferCore. To avoid pulling
// a GRDB dependency into a lightweight unit test, we mirror the
// `normalizeTag` rule here as a regression test on the *intent*: the
// algorithm stays lowercase, trims, and collapses whitespace. If the
// app-side implementation diverges, this test will need updating in
// both places — the friction is intentional (keeps the rule visible).

final class TagNormalizationTests: XCTestCase {
    static func normalizeTag(_ raw: String) -> String {
        let parts = raw.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    func testLowercases() {
        XCTAssertEqual(Self.normalizeTag("Work"), "work")
    }

    func testCollapsesInternalWhitespace() {
        XCTAssertEqual(Self.normalizeTag("deep   work"), "deep work")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(Self.normalizeTag("  research  "), "research")
    }

    func testPureWhitespaceReturnsEmpty() {
        XCTAssertEqual(Self.normalizeTag("   \n\t  "), "")
    }

    func testEmptyReturnsEmpty() {
        XCTAssertEqual(Self.normalizeTag(""), "")
    }

    func testPreservesUnicode() {
        XCTAssertEqual(Self.normalizeTag("日本語 メモ"), "日本語 メモ")
    }

    func testPreservesPunctuationInsideTag() {
        // Punctuation stays — tags like "c++" or "q&a" should round-trip.
        XCTAssertEqual(Self.normalizeTag("C++"), "c++")
        XCTAssertEqual(Self.normalizeTag("Q&A"), "q&a")
    }
}
