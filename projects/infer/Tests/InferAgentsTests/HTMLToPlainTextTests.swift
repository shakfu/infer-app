import XCTest
@testable import InferAgents

final class HTMLToPlainTextTests: XCTestCase {
    func testDropsNonContentElements() {
        let html = """
        <head><title>x</title></head><!-- note --><script type="a">s()</script><STYLE>b{}</STYLE>
        <noscript>n</noscript><svg><text>v</text></svg>Body
        """
        XCTAssertEqual(htmlToPlainText(html), "Body")
    }

    func testBlockTagsBreakLinesAndInlineTagsDoNot() {
        XCTAssertEqual(htmlToPlainText("<p>one <b>two</b></p><p>three</p>"), "one two\n\nthree")
        XCTAssertEqual(htmlToPlainText("a<br/>b"), "a\nb")
    }

    func testDoesNotConfuseTagPrefixes() {
        XCTAssertEqual(htmlToPlainText("<picture>x</picture><header>y</header>"), "x\ny")
    }

    func testDecodesEntitiesAndCollapsesWhitespace() {
        XCTAssertEqual(htmlToPlainText("  a&nbsp;&nbsp;b \t c &lt;d&gt;\n\n\n\ne "), "a b c <d>\n\ne")
    }

    func testCommentsSpanLines() {
        XCTAssertEqual(htmlToPlainText("a<!-- x\ny -->b"), "ab")
    }
}
