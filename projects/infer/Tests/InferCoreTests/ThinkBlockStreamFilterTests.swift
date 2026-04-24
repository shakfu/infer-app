import XCTest
@testable import InferCore

final class ThinkBlockStreamFilterTests: XCTestCase {
    // MARK: - No tags

    func testPlainTextPassesThrough() {
        var f = ThinkBlockStreamFilter()
        XCTAssertEqual(f.feed("hello world"), "hello world")
        XCTAssertEqual(f.flush(), "")
        XCTAssertEqual(f.thinking, "")
        XCTAssertFalse(f.inThink)
    }

    func testEmptyFeedsAreNoops() {
        var f = ThinkBlockStreamFilter()
        XCTAssertEqual(f.feed(""), "")
        XCTAssertEqual(f.flush(), "")
        XCTAssertEqual(f.thinking, "")
    }

    // MARK: - Single complete block in one piece

    func testSingleBlockInOnePiece() {
        var f = ThinkBlockStreamFilter()
        let out = f.feed("intro <think>reasoning here</think> answer")
        XCTAssertEqual(out, "intro  answer")
        XCTAssertEqual(f.thinking, "reasoning here")
        XCTAssertEqual(f.flush(), "")
    }

    func testThinkOnly() {
        var f = ThinkBlockStreamFilter()
        let out = f.feed("<think>just thinking</think>")
        XCTAssertEqual(out, "")
        XCTAssertEqual(f.thinking, "just thinking")
    }

    // MARK: - Tags split across pieces

    func testOpenTagSplitAcrossTwoPieces() {
        var f = ThinkBlockStreamFilter()
        // First piece ends mid-tag; nothing should be released yet
        // because "intro <thi" might be the start of "<think>".
        let out1 = f.feed("intro <thi")
        XCTAssertEqual(out1, "intro ")  // safe up to the partial tag
        XCTAssertFalse(f.inThink)
        let out2 = f.feed("nk>thoughts</think>final")
        XCTAssertEqual(out2, "final")
        XCTAssertEqual(f.thinking, "thoughts")
    }

    func testCloseTagSplitAcrossPieces() {
        var f = ThinkBlockStreamFilter()
        XCTAssertEqual(f.feed("<think>a"), "")
        XCTAssertEqual(f.feed("b</thi"), "")  // held back
        XCTAssertEqual(f.feed("nk>after"), "after")
        XCTAssertEqual(f.thinking, "ab")
    }

    func testTagSplitOneCharAtATime() {
        // Worst case: every character arrives in its own chunk.
        var f = ThinkBlockStreamFilter()
        let stream = "pre <think>x</think> post"
        var out = ""
        for ch in stream {
            out += f.feed(String(ch))
        }
        out += f.flush()
        XCTAssertEqual(out, "pre  post")
        XCTAssertEqual(f.thinking, "x")
    }

    // MARK: - False-positive partial tag

    func testPendingThatDoesNotResolveToTagFlushesOnEnd() {
        var f = ThinkBlockStreamFilter()
        // "<thi" looks like the start of <think> but turns out to
        // be a literal angle-bracket fragment. flush() releases it.
        let out = f.feed("hello <thi")
        XCTAssertEqual(out, "hello ")
        let tail = f.flush()
        XCTAssertEqual(tail, "<thi")
        XCTAssertEqual(f.thinking, "")
    }

    func testPendingThatLooksLikeOpenTagButIsLiteral() {
        var f = ThinkBlockStreamFilter()
        // "<think" without ">" is still a valid prefix of <think>,
        // so we hold it. When we get something that breaks the tag
        // ("<think this"), the held text releases.
        XCTAssertEqual(f.feed("<thin"), "")
        let out = f.feed("k literally")
        // After consuming "k", pending becomes "<think literally";
        // "<think " is no longer a prefix of "<think>" (mismatch
        // at position 6), so the entire pending releases.
        XCTAssertEqual(out, "<think literally")
        XCTAssertFalse(f.inThink)
    }

    // MARK: - Multiple blocks

    func testMultipleThinkBlocks() {
        var f = ThinkBlockStreamFilter()
        let out = f.feed("a<think>one</think>b<think>two</think>c")
        XCTAssertEqual(out, "abc")
        XCTAssertEqual(f.thinking, "onetwo")
    }

    // MARK: - Unterminated think block

    func testUnterminatedThinkCapturesTailIntoThinking() {
        var f = ThinkBlockStreamFilter()
        XCTAssertEqual(f.feed("intro <think>reasoning"), "intro ")
        // No close tag arrives. flush() should capture remaining
        // pending as thinking, not output.
        XCTAssertEqual(f.flush(), "")
        XCTAssertEqual(f.thinking, "reasoning")
        XCTAssertTrue(f.inThink)
    }

    // MARK: - Adjacent text with no whitespace

    func testTagsAdjacentToText() {
        var f = ThinkBlockStreamFilter()
        let out = f.feed("before<think>mid</think>after")
        XCTAssertEqual(out, "beforeafter")
        XCTAssertEqual(f.thinking, "mid")
    }

    // MARK: - Empty think block

    func testEmptyThinkBlock() {
        var f = ThinkBlockStreamFilter()
        let out = f.feed("a<think></think>b")
        XCTAssertEqual(out, "ab")
        XCTAssertEqual(f.thinking, "")
        XCTAssertFalse(f.inThink)
    }

    // MARK: - Cumulative state

    func testInThinkExposesLiveState() {
        var f = ThinkBlockStreamFilter()
        XCTAssertFalse(f.inThink)
        _ = f.feed("text <think>")
        XCTAssertTrue(f.inThink)
        _ = f.feed("middle")
        XCTAssertTrue(f.inThink)
        _ = f.feed("</think>")
        XCTAssertFalse(f.inThink)
    }
}
