import XCTest
@testable import InferCore

final class StopSequenceMatcherTests: XCTestCase {
    func testNoStopsPassesThrough() {
        var m = StopSequenceMatcher([])
        XCTAssertEqual(m.feed("hello </answer> world"), "hello </answer> world")
        XCTAssertEqual(m.flush(), "")
        XCTAssertFalse(m.stopped)
    }

    func testEmptyStopStringsAreIgnored() {
        var m = StopSequenceMatcher(["", ""])
        XCTAssertEqual(m.feed("abc"), "abc")
        XCTAssertFalse(m.stopped)
    }

    func testMatchInOneChunkTruncatesBeforeStop() {
        var m = StopSequenceMatcher(["</answer>"])
        XCTAssertEqual(m.feed("42</answer> trailing"), "42")
        XCTAssertTrue(m.stopped)
        XCTAssertEqual(m.feed("more"), "")
        XCTAssertEqual(m.flush(), "")
    }

    func testMatchSplitAcrossChunksIsNeverPartiallyEmitted() {
        var m = StopSequenceMatcher(["---"])
        XCTAssertEqual(m.feed("line -"), "line ")
        XCTAssertEqual(m.feed("-"), "")
        XCTAssertEqual(m.feed("- after"), "")
        XCTAssertTrue(m.stopped)
    }

    func testHeldTailReleasedWhenItDiverges() {
        var m = StopSequenceMatcher(["</answer>"])
        XCTAssertEqual(m.feed("a </ans"), "a ")
        XCTAssertEqual(m.feed("wer is"), "</answer is")
        XCTAssertFalse(m.stopped)
    }

    func testFlushReleasesHeldTailAtEndOfStream() {
        var m = StopSequenceMatcher(["STOP"])
        XCTAssertEqual(m.feed("go ST"), "go ")
        XCTAssertEqual(m.flush(), "ST")
        XCTAssertFalse(m.stopped)
    }

    func testEarliestOfSeveralStopsWins() {
        var m = StopSequenceMatcher(["END", "##"])
        XCTAssertEqual(m.feed("x ## y END"), "x ")
        XCTAssertTrue(m.stopped)
    }

    func testStopAtVeryStartEmitsNothing() {
        var m = StopSequenceMatcher(["\n\n"])
        XCTAssertEqual(m.feed("\n"), "")
        XCTAssertEqual(m.feed("\nbody"), "")
        XCTAssertTrue(m.stopped)
    }

    func testMultibyteTextSurvivesHolding() {
        var m = StopSequenceMatcher(["ende"])
        XCTAssertEqual(m.feed("grüße en"), "grüße ")
        XCTAssertEqual(m.feed("d"), "")
        XCTAssertEqual(m.feed("x é"), "endx é")
    }
}
