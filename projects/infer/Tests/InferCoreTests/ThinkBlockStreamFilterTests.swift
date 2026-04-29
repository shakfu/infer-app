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

    // MARK: - Sentinel-mode (token-ID-authoritative think tags)

    /// The runner emits PUA sentinels when the special-token IDs for
    /// `<think>` / `</think>` fire. Once seen, the filter should treat
    /// the boundary as authoritative and ignore subsequent surface-form
    /// `</think>` strings — the model can write `</think>` inside its
    /// reasoning (e.g. quoted prose) and we must not exit thinking.
    func testSentinelOpenAndClose() {
        var f = ThinkBlockStreamFilter()
        let out = f.feed("\(ThinkBlockStreamFilter.openSentinel)reasoning\(ThinkBlockStreamFilter.closeSentinel)answer")
        XCTAssertEqual(out, "answer")
        XCTAssertEqual(f.thinking, "reasoning")
        XCTAssertFalse(f.inThink)
    }

    /// Repro of the "model emits `</think>` inside its quoted prose"
    /// failure that motivated this feature: the literal close tag must
    /// not terminate thinking once the sentinel has flipped the filter
    /// into authoritative mode.
    func testSentinelModeIgnoresLiteralCloseTagInsideThinking() {
        var f = ThinkBlockStreamFilter()
        var out = ""
        out += f.feed(ThinkBlockStreamFilter.openSentinel)
        out += f.feed("Okay, the user is asking. The initial message is just \"</think>\", which doesn't make sense in English. Let me think more.")
        out += f.feed(ThinkBlockStreamFilter.closeSentinel)
        out += f.feed("The answer is 42.")
        XCTAssertEqual(out, "The answer is 42.")
        XCTAssertTrue(f.thinking.contains("</think>"))
        XCTAssertTrue(f.thinking.contains("Let me think more."))
        XCTAssertFalse(f.inThink)
    }

    /// Sentinel mode persists across feeds — once the runner has signalled
    /// authoritative boundaries, the filter never falls back to string
    /// matching for the remainder of the stream.
    func testSentinelModePersistsAcrossFeeds() {
        var f = ThinkBlockStreamFilter()
        _ = f.feed(ThinkBlockStreamFilter.openSentinel)
        _ = f.feed("inside thinking")
        _ = f.feed(ThinkBlockStreamFilter.closeSentinel)
        // After close: a literal `<think>` string must not re-enter thinking.
        let out = f.feed("body <think>literal</think> body")
        XCTAssertEqual(out, "body <think>literal</think> body")
        XCTAssertFalse(f.inThink)
        XCTAssertEqual(f.thinking, "inside thinking")
    }

    /// Sentinel mid-piece: open and close sentinels split a single
    /// piece into thinking + body in one feed. Drains any pre-sentinel
    /// pending buffer first.
    func testSentinelsMidPiece() {
        var f = ThinkBlockStreamFilter()
        let out = f.feed("intro \(ThinkBlockStreamFilter.openSentinel)reasoning\(ThinkBlockStreamFilter.closeSentinel) reply")
        XCTAssertEqual(out, "intro  reply")
        XCTAssertEqual(f.thinking, "reasoning")
    }
}
