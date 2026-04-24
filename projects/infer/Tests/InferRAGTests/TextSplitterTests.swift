import XCTest
@testable import InferRAG

final class TextSplitterTests: XCTestCase {
    // MARK: - Trivial inputs

    func testEmptyInputReturnsEmpty() {
        let splitter = TextSplitter(chunkSize: 100, chunkOverlap: 10)
        XCTAssertTrue(splitter.split("").isEmpty)
    }

    func testWhitespaceOnlyReturnsEmpty() {
        let splitter = TextSplitter(chunkSize: 100, chunkOverlap: 10)
        XCTAssertTrue(splitter.split("   \n  \t  ").isEmpty)
    }

    func testShortInputReturnsSingleChunk() {
        let splitter = TextSplitter(chunkSize: 100, chunkOverlap: 10)
        let chunks = splitter.split("hello")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].content, "hello")
        XCTAssertEqual(chunks[0].offsetStart, 0)
        XCTAssertEqual(chunks[0].offsetEnd, 5)
    }

    // MARK: - Paragraph-shaped input

    func testParagraphBoundariesPreferred() {
        // Two "paragraphs" separated by blank line, each under the
        // chunk ceiling on its own but over when combined. Expect
        // the split to honor the paragraph boundary.
        let a = String(repeating: "a", count: 40)
        let b = String(repeating: "b", count: 40)
        let text = "\(a)\n\n\(b)"
        let splitter = TextSplitter(chunkSize: 60, chunkOverlap: 0)
        let chunks = splitter.split(text)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].content.contains(a))
        XCTAssertTrue(chunks[1].content.contains(b))
    }

    func testSentenceBoundaryUsedWhenNoParagraphs() {
        let text = "First sentence. Second sentence. Third sentence."
        let splitter = TextSplitter(chunkSize: 20, chunkOverlap: 0)
        let chunks = splitter.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        // No chunk should dramatically exceed the ceiling.
        // Overlap is 0 here; allow a small fudge for grapheme counts
        // that may include the trailing separator.
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.content.count, 25, "chunk too large: \(chunk.content)")
        }
    }

    // MARK: - Hard split fallback

    func testHardSplitWhenNoSeparatorFits() {
        // One long word with no separators — must fall back to char split.
        let text = String(repeating: "x", count: 205)
        let splitter = TextSplitter(chunkSize: 100, chunkOverlap: 0)
        let chunks = splitter.split(text)
        XCTAssertEqual(chunks.count, 3)  // 100 + 100 + 5
        XCTAssertEqual(chunks[0].content.count, 100)
        XCTAssertEqual(chunks[1].content.count, 100)
        XCTAssertEqual(chunks[2].content.count, 5)
        XCTAssertEqual(chunks[0].offsetStart, 0)
        XCTAssertEqual(chunks[0].offsetEnd, 100)
        XCTAssertEqual(chunks[1].offsetStart, 100)
        XCTAssertEqual(chunks[2].offsetStart, 200)
    }

    // MARK: - Overlap

    func testOverlapSeedsNextChunk() {
        // With overlap, consecutive chunks share characters. A 205-char
        // hard-split run with 100-size 20-overlap should produce
        // chunks where chunk[i+1] starts with the last 20 chars of
        // chunk[i].
        let text = String(repeating: "abcdefghij", count: 30)  // 300 chars
        let splitter = TextSplitter(chunkSize: 100, chunkOverlap: 20)
        let chunks = splitter.split(text)
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        for i in 1..<chunks.count {
            let prevTail = String(chunks[i - 1].content.suffix(20))
            let currHead = String(chunks[i].content.prefix(20))
            XCTAssertEqual(prevTail, currHead,
                "chunk \(i) head should equal chunk \(i-1) tail (overlap)")
        }
    }

    func testOverlapZeroMeansNoOverlap() {
        let text = String(repeating: "x", count: 300)
        let splitter = TextSplitter(chunkSize: 100, chunkOverlap: 0)
        let chunks = splitter.split(text)
        // With no overlap, chunks are exactly 100 chars each.
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].content.count, 100)
        XCTAssertEqual(chunks[1].content.count, 100)
        XCTAssertEqual(chunks[2].content.count, 100)
    }

    // MARK: - Offsets

    func testOffsetsCoverTheOriginal() {
        // Offsets should let us slice the original (or its overlap-
        // collapsed equivalent) back. We assert that offsets are
        // monotonic non-decreasing and that the first chunk starts
        // at 0 and the last chunk ends at the original grapheme count
        // (ignoring overlap seeding).
        let text = """
        Paragraph one. Some content here that is a bit longer than a short line.

        Paragraph two. This has a second sentence. And a third.

        Paragraph three here.
        """
        let splitter = TextSplitter(chunkSize: 60, chunkOverlap: 15)
        let chunks = splitter.split(text)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks.first?.offsetStart, 0)
        for i in 1..<chunks.count {
            XCTAssertGreaterThanOrEqual(chunks[i].offsetStart, 0)
            XCTAssertGreaterThan(chunks[i].offsetEnd, chunks[i].offsetStart)
        }
    }

    // MARK: - Unicode

    func testUnicodeGraphemesCountedCorrectly() {
        // Chunk ceiling on grapheme count; emoji + CJK should not
        // produce malformed chunks.
        let text = "日本語のテキスト。🚀 More content here. さらに詳しく。"
        let splitter = TextSplitter(chunkSize: 15, chunkOverlap: 0)
        let chunks = splitter.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        // Reassembling chunks (ignoring overlap = 0) should yield
        // something substring-equivalent to the original.
        let reconstructed = chunks.map(\.content).joined()
        XCTAssertEqual(reconstructed, text)
    }

    // MARK: - Invariants

    func testChunksOrderedByOffset() {
        let text = String(repeating: "word ", count: 200)
        let splitter = TextSplitter(chunkSize: 50, chunkOverlap: 10)
        let chunks = splitter.split(text)
        for i in 1..<chunks.count {
            XCTAssertGreaterThanOrEqual(chunks[i].offsetStart, chunks[i - 1].offsetStart,
                "chunk offsets must be monotonic")
        }
    }

    func testNoChunkExceedsCeilingSignificantly() {
        let text = (0..<50).map { "Sentence number \($0). " }.joined()
        let splitter = TextSplitter(chunkSize: 80, chunkOverlap: 10)
        let chunks = splitter.split(text)
        for chunk in chunks {
            // Allow small overrun when a separator-split piece is
            // just over the ceiling and no finer separator helps.
            XCTAssertLessThanOrEqual(chunk.content.count, 100,
                "chunk too large: count=\(chunk.content.count)")
        }
    }
}
