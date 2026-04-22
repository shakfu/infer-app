import XCTest
@testable import InferCore

final class VoiceTriggerTests: XCTestCase {
    private func strip(_ text: String, _ phrase: String = "send it") -> String? {
        VoiceTrigger.stripTrailingTrigger(text, phrase: phrase)
    }

    func testMatchesBasicTrailingPhrase() {
        XCTAssertEqual(strip("hello there send it"), "hello there")
    }

    func testStripsTrailingPunctuationBeforeMatching() {
        XCTAssertEqual(strip("do the thing, send it."), "do the thing")
        XCTAssertEqual(strip("send it!!"), "")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(strip("Hello SEND IT"), "Hello")
        XCTAssertEqual(strip("hello Send It"), "hello")
    }

    func testRequiresWordBoundary() {
        // "resend it" must not match the trigger "send it".
        XCTAssertNil(strip("please resend it"))
    }

    func testEmptyPhraseReturnsNil() {
        XCTAssertNil(strip("anything send it", ""))
        XCTAssertNil(strip("anything send it", "   "))
    }

    func testTextShorterThanPhraseReturnsNil() {
        XCTAssertNil(strip("hi"))
        XCTAssertNil(strip(""))
    }

    func testPhraseInMiddleDoesNotMatch() {
        XCTAssertNil(strip("send it now please"))
    }

    func testCustomPhrase() {
        XCTAssertEqual(
            VoiceTrigger.stripTrailingTrigger("please respond, over", phrase: "over"),
            "please respond"
        )
    }
}
