import XCTest
@testable import InferCore

final class TranscriptMarkdownTests: XCTestCase {
    func testRoundTripSingleTurn() {
        let turns = [TranscriptMarkdown.Turn(role: "user", text: "hello")]
        let md = TranscriptMarkdown.render(turns)
        XCTAssertEqual(TranscriptMarkdown.parse(md), turns)
    }

    func testRoundTripMultipleRoles() {
        let turns = [
            TranscriptMarkdown.Turn(role: "system", text: "you are helpful"),
            TranscriptMarkdown.Turn(role: "user", text: "hi"),
            TranscriptMarkdown.Turn(role: "assistant", text: "hello, how can I help?"),
        ]
        XCTAssertEqual(TranscriptMarkdown.parse(TranscriptMarkdown.render(turns)), turns)
    }

    func testParseSkipsUnknownRoles() {
        let md = """
        ## user

        first

        ---

        ## robot

        should be skipped

        ---

        ## assistant

        second
        """
        let parsed = TranscriptMarkdown.parse(md)
        XCTAssertEqual(parsed.map { $0.role }, ["user", "assistant"])
        XCTAssertEqual(parsed.map { $0.text }, ["first", "second"])
    }

    func testParseHandlesContentWithHorizontalRulesInside() {
        // Content is allowed to contain `---` as long as it isn't surrounded
        // by the exact `\n\n---\n\n` separator — an `---` on its own line
        // with other text around it should survive as part of the body.
        let turns = [
            TranscriptMarkdown.Turn(role: "assistant", text: "line1\n---\nline2"),
        ]
        let md = TranscriptMarkdown.render(turns)
        XCTAssertEqual(TranscriptMarkdown.parse(md), turns)
    }

    func testParseEmptyInputReturnsEmpty() {
        XCTAssertEqual(TranscriptMarkdown.parse(""), [])
    }

    func testParseMalformedReturnsEmpty() {
        XCTAssertEqual(TranscriptMarkdown.parse("this is not a transcript"), [])
    }

    func testRoleHeaderIsCaseInsensitive() {
        let md = "## USER\n\nhello"
        let parsed = TranscriptMarkdown.parse(md)
        XCTAssertEqual(parsed, [TranscriptMarkdown.Turn(role: "user", text: "hello")])
    }
}
