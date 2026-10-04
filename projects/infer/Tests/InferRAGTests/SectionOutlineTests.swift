import XCTest
@testable import InferRAG

final class SectionOutlineTests: XCTestCase {
    func testNestedATXHeadingsBuildPaths() {
        let text = "# Plan\nintro\n## 3.1 Schema\nbody\n### Columns\nx\n## 3.2 Queries\ny"
        let o = SectionOutline(text)
        XCTAssertEqual(o.headings.map(\.path), [
            ["Plan"],
            ["Plan", "3.1 Schema"],
            ["Plan", "3.1 Schema", "Columns"],
            ["Plan", "3.2 Queries"],
        ])
        XCTAssertEqual(o.label(at: text.count - 1), "Plan > 3.2 Queries")
    }

    func testNoLabelBeforeFirstHeading() {
        let o = SectionOutline("preamble\n# Title\nbody")
        XCTAssertNil(o.label(at: 0))
        XCTAssertEqual(o.label(at: 9), "Title")
    }

    func testHeadingsInsideFencedCodeAreIgnored() {
        let o = SectionOutline("# Real\n```\n# not a heading\n```\n~~~\n## nor this\n~~~\n")
        XCTAssertEqual(o.headings.map(\.path), [["Real"]])
    }

    func testATXEdgeCases() {
        XCTAssertNil(SectionOutline.atxHeading("#hashtag"))
        XCTAssertNil(SectionOutline.atxHeading("    # indented code"))
        XCTAssertNil(SectionOutline.atxHeading("####### seven"))
        XCTAssertEqual(SectionOutline.atxHeading("## Closed ##")?.title, "Closed")
        XCTAssertEqual(SectionOutline.atxHeading("   ### Three spaces")?.level, 3)
    }

    func testPlainTextChapterMarkersNestUnderParts() {
        let o = SectionOutline("PART I\n\nChapter 1\ntext\nCHAPTER Two: The Road\nmore\nPart II\nChapter 3")
        XCTAssertEqual(o.headings.map(\.path), [
            ["PART I"],
            ["PART I", "Chapter 1"],
            ["PART I", "CHAPTER Two: The Road"],
            ["Part II"],
            ["Part II", "Chapter 3"],
        ])
    }

    func testProseStartingWithKeywordIsNotAChapter() {
        XCTAssertNil(SectionOutline.chapterHeading("Part of the problem is scope."))
        XCTAssertNil(SectionOutline.chapterHeading("Chapter and verse"))
    }

    func testChapterMarkersIgnoredWhenATXHeadingsExist() {
        let o = SectionOutline("# Notes\nChapter 1\nbody")
        XCTAssertEqual(o.headings.map(\.path), [["Notes"]])
    }

    func testChunkLabelSkipsOverlapPrefix() {
        // Chunk opens with 5 chars of the previous section, then a heading.
        let text = "# A\naaaaa\n# B\nbbbbb"
        let o = SectionOutline(text)
        let start = 4  // "aaaaa"
        let chunk = TextChunk(content: "aaaaa\n# B\nbbbbb", offsetStart: start, offsetEnd: text.count)
        XCTAssertEqual(o.label(at: start), "A")
        XCTAssertEqual(o.label(for: chunk, overlap: 6), "B")
    }

    func testLongLabelsKeepInnermostHeadings() {
        let deep = (1...6).map { String(repeating: "#", count: $0) + " " + String(repeating: "h\($0)", count: 20) }
        let o = SectionOutline(deep.joined(separator: "\n"))
        let label = o.label(at: Int.max)!
        XCTAssertEqual(label.count, SectionOutline.maxLabelLength)
        XCTAssertTrue(label.hasPrefix("…"))
        XCTAssertTrue(label.hasSuffix(String(repeating: "h6", count: 20)))
    }
}
