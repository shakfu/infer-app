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
        XCTAssertEqual(htmlToPlainText("<picture>x</picture><pre>y</pre><navigator>z</navigator>"), "x\ny\nz")
    }

    func testDecodesEntitiesAndCollapsesWhitespace() {
        XCTAssertEqual(htmlToPlainText("  a&nbsp;&nbsp;b \t c &lt;d&gt;\n\n\n\ne "), "a b c <d>\n\ne")
    }

    func testDropsPageChromeWithoutAMainElement() {
        let html = """
        <header><a>Logo</a></header><nav><a>Home</a></nav><aside>Ad</aside>
        <div>Story</div><form><label>Email</label></form><footer>Copyright</footer>
        """
        XCTAssertEqual(htmlToPlainText(html), "Story")
    }

    func testPrefersMainAndKeepsItsHeader() {
        let html = "<nav>Menu</nav><div>Promo</div><main><header><h1>Title</h1></header><p>Body</p></main><footer>F</footer>"
        XCTAssertEqual(htmlToPlainText(html), "Title\n\nBody")
    }

    func testPrefersArticleWhenNoMain() {
        let html = "<div>Promo</div><article><p>One</p></article><div>Between</div><article><p>Two</p></article><div>After</div>"
        let text = htmlToPlainText(html)
        XCTAssertTrue(text.contains("One") && text.contains("Two"))
        XCTAssertFalse(text.contains("Promo") || text.contains("After"))
    }

    /// A JavaScript page can ship an empty `<main>`.
    func testEmptyMainFallsBackToThePage() {
        XCTAssertEqual(htmlToPlainText("<main><script>a()</script></main><div>Text</div>"), "Text")
    }

    func testLargePageCompletes() {
        let row = "<nav>m</nav><div>word word word</div><script>x()</script>\n"
        let html = String(repeating: row, count: 20_000)
        let text = htmlToPlainText(html)
        XCTAssertTrue(text.hasPrefix("word word word"))
        XCTAssertFalse(text.contains("x()"))
    }

    func testCommentsSpanLines() {
        XCTAssertEqual(htmlToPlainText("a<!-- x\ny -->b"), "ab")
    }
}
