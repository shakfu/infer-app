import XCTest
@testable import InferCore

final class ChatPromptDeltaTests: XCTestCase {
    func testFirstTurnReturnsEntirePrompt() {
        let full = "<|system|>you are helpful<|user|>hello<|assistant|>"
        XCTAssertEqual(
            ChatPromptDelta.delta(fullRendered: full, previousByteLength: 0),
            full
        )
    }

    func testSubsequentTurnReturnsSuffixAfterPrevLength() {
        let priorRender = "<|system|>s<|user|>u1<|assistant|>a1"
        let prevLen = priorRender.utf8.count
        let next = priorRender + "<|user|>u2<|assistant|>"
        XCTAssertEqual(
            ChatPromptDelta.delta(fullRendered: next, previousByteLength: prevLen),
            "<|user|>u2<|assistant|>"
        )
    }

    func testByteLengthMatchesUtf8Count() {
        let s = "hello"
        XCTAssertEqual(ChatPromptDelta.byteLength(of: s), 5)
    }

    func testMultibyteByteLengthCountsUtf8Bytes() {
        // "café" = 5 UTF-8 bytes (the é is 2 bytes) even though it's 4 Characters.
        let s = "café"
        XCTAssertEqual(ChatPromptDelta.byteLength(of: s), 5)
        XCTAssertNotEqual(s.count, ChatPromptDelta.byteLength(of: s))
    }

    func testDeltaHandlesMultibyteBoundary() {
        // Boundary between prior and new content lands cleanly on a UTF-8
        // boundary — the normal case when both renders start from the same
        // template and only append.
        let prior = "prefix café "
        let prevLen = prior.utf8.count
        let full = prior + "naïveté"
        XCTAssertEqual(
            ChatPromptDelta.delta(fullRendered: full, previousByteLength: prevLen),
            "naïveté"
        )
    }

    func testPreviousLengthAtEndReturnsEmpty() {
        let s = "whole prompt"
        XCTAssertEqual(
            ChatPromptDelta.delta(fullRendered: s, previousByteLength: s.utf8.count),
            ""
        )
    }

    func testPreviousLengthBeyondEndIsClampedNotCrash() {
        // Defensive: if the caller passes a stale length larger than the
        // current render, we return empty rather than trapping.
        let s = "short"
        XCTAssertEqual(
            ChatPromptDelta.delta(fullRendered: s, previousByteLength: 9999),
            ""
        )
    }

    func testNegativePreviousLengthTreatedAsFirstTurn() {
        let s = "prompt"
        XCTAssertEqual(
            ChatPromptDelta.delta(fullRendered: s, previousByteLength: -1),
            s
        )
    }

    func testEmptyFullRenderedReturnsEmpty() {
        XCTAssertEqual(ChatPromptDelta.delta(fullRendered: "", previousByteLength: 0), "")
        XCTAssertEqual(ChatPromptDelta.delta(fullRendered: "", previousByteLength: 10), "")
    }
}
