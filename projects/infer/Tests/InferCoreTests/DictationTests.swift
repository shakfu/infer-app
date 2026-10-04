import XCTest
@testable import InferCore

final class PushToTalkGestureTests: XCTestCase {
    private let key = PushToTalkKey.rightOption

    func testPressAndReleaseBeginsAndEnds() {
        var g = PushToTalkGesture(key: key)
        XCTAssertEqual(g.flagsChanged(keyCode: key.keyCode, keyIsDown: true), .begin)
        XCTAssertTrue(g.holding)
        XCTAssertEqual(g.flagsChanged(keyCode: key.keyCode, keyIsDown: false), .end)
        XCTAssertFalse(g.holding)
    }

    func testOtherModifiersAreIgnored() {
        var g = PushToTalkGesture(key: key)
        XCTAssertNil(g.flagsChanged(keyCode: PushToTalkKey.rightCommand.keyCode, keyIsDown: true))
        XCTAssertNil(g.flagsChanged(keyCode: 56, keyIsDown: true))  // left shift
        XCTAssertFalse(g.holding)
    }

    func testKeyDownDuringHoldIsAChordAndSuppressesEnd() {
        var g = PushToTalkGesture(key: key)
        _ = g.flagsChanged(keyCode: key.keyCode, keyIsDown: true)
        XCTAssertEqual(g.keyDown(), .chord)
        XCTAssertNil(g.keyDown(), "chord reported once per hold")
        XCTAssertNil(g.flagsChanged(keyCode: key.keyCode, keyIsDown: false))
    }

    func testChordStateResetsOnNextHold() {
        var g = PushToTalkGesture(key: key)
        _ = g.flagsChanged(keyCode: key.keyCode, keyIsDown: true)
        _ = g.keyDown()
        _ = g.flagsChanged(keyCode: key.keyCode, keyIsDown: false)
        XCTAssertEqual(g.flagsChanged(keyCode: key.keyCode, keyIsDown: true), .begin)
        XCTAssertEqual(g.flagsChanged(keyCode: key.keyCode, keyIsDown: false), .end)
    }

    func testKeyDownWithoutHoldIsIgnored() {
        var g = PushToTalkGesture(key: key)
        XCTAssertNil(g.keyDown())
    }

    func testRepeatedDownOrUpEventsAreIdempotent() {
        var g = PushToTalkGesture(key: key)
        XCTAssertNil(g.flagsChanged(keyCode: key.keyCode, keyIsDown: false))
        XCTAssertEqual(g.flagsChanged(keyCode: key.keyCode, keyIsDown: true), .begin)
        XCTAssertNil(g.flagsChanged(keyCode: key.keyCode, keyIsDown: true))
    }
}

final class WhisperTextTests: XCTestCase {
    func testStripsAnnotations() {
        XCTAssertEqual(WhisperText.clean(" [BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperText.clean(" Hello there. [MUSIC] How are you?"), "Hello there. How are you?")
        XCTAssertEqual(WhisperText.clean("(silence) okay"), "okay")
    }

    func testUnclosedAnnotationAtEndIsDropped() {
        XCTAssertEqual(WhisperText.clean("send it [BLANK_"), "send it")
    }

    func testPlainTextCollapsesWhitespace() {
        XCTAssertEqual(WhisperText.clean("  one\n two  "), "one two")
    }
}
