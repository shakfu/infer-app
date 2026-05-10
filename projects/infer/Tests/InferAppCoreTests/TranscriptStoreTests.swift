import XCTest
@testable import InferAppCore

final class TranscriptStoreTests: XCTestCase {

    // MARK: append / streaming

    func testAppendUserAddsRowAndReturnsId() {
        var store = TranscriptStore()
        let id = store.appendUser("hello")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].id, id)
        XCTAssertEqual(store.entries[0].role, .user)
        XCTAssertEqual(store.entries[0].text, "hello")
    }

    func testBeginAssistantThenAppendChunksConcatenates() {
        var store = TranscriptStore()
        _ = store.appendUser("ping")
        let aid = store.beginAssistant()
        store.appendChunk("po", to: aid)
        store.appendChunk("ng", to: aid)
        XCTAssertEqual(store.entries.last?.text, "pong")
        XCTAssertEqual(store.entries.last?.role, .assistant)
    }

    func testAppendChunkToUnknownIdIsNoOp() {
        // F-8 race window: the user clicked "edit" mid-stream, the row
        // was truncated away, and a late chunk arrives. Must not crash
        // and must not resurrect the row.
        var store = TranscriptStore()
        _ = store.appendUser("ping")
        let stale = UUID()
        store.appendChunk("ghost", to: stale)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "ping")
    }

    func testSetTextReplacesRowText() {
        var store = TranscriptStore()
        _ = store.appendUser("hi")
        let aid = store.beginAssistant()
        store.appendChunk("rough draft", to: aid)
        store.setText("clean reply", for: aid)
        XCTAssertEqual(store.entries.last?.text, "clean reply")
    }

    func testResetClearsAllEntries() {
        var store = TranscriptStore()
        _ = store.appendUser("a")
        _ = store.beginAssistant()
        store.reset()
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: edit-and-resend

    func testEditAndResendOnUserTurnTruncatesAndRewrites() {
        var store = TranscriptStore()
        let u1 = store.appendUser("first")
        let a1 = store.beginAssistant()
        store.appendChunk("first reply", to: a1)
        _ = store.appendUser("second")
        _ = store.beginAssistant()

        let dropped = store.editAndResend(messageId: u1, newText: "FIRST EDITED")
        XCTAssertNotNil(dropped)
        XCTAssertEqual(dropped?.count, 3) // a1, u2, a2
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].role, .user)
        XCTAssertEqual(store.entries[0].text, "FIRST EDITED")
    }

    func testEditAndResendOnAssistantTurnReturnsNil() {
        var store = TranscriptStore()
        _ = store.appendUser("u")
        let aid = store.beginAssistant()
        let result = store.editAndResend(messageId: aid, newText: "nope")
        XCTAssertNil(result)
        XCTAssertEqual(store.entries.count, 2, "store must not mutate when the target is not a user turn")
    }

    func testEditAndResendOnUnknownIdReturnsNil() {
        var store = TranscriptStore()
        _ = store.appendUser("u")
        let result = store.editAndResend(messageId: UUID(), newText: "nope")
        XCTAssertNil(result)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testEditAndResendPreservesOriginalImageAttachment() {
        var store = TranscriptStore()
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        let u1 = store.appendUser("describe", imageURL: url)
        _ = store.beginAssistant()
        _ = store.editAndResend(messageId: u1, newText: "describe in detail")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].imageURL, url,
            "the rewritten user turn must carry the original turn's image, not lose it")
    }

    // MARK: regenerate

    func testRegenerateDropsTrailingAssistantAndReturnsPriorUserText() {
        var store = TranscriptStore()
        _ = store.appendUser("ping")
        let aid = store.beginAssistant()
        store.appendChunk("pong", to: aid)
        let resend = store.regenerate()
        XCTAssertEqual(resend, "ping")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.last?.role, .user)
    }

    func testRegenerateWithTrailingUserReturnsNil() {
        var store = TranscriptStore()
        _ = store.appendUser("ping")
        let result = store.regenerate()
        XCTAssertNil(result)
        XCTAssertEqual(store.entries.count, 1, "store must not mutate when there's no assistant to regen")
    }

    func testRegenerateOnEmptyStoreReturnsNil() {
        var store = TranscriptStore()
        let result = store.regenerate()
        XCTAssertNil(result)
    }

    func testRegenerateRequiresAssistantImmediatelyAfterUser() {
        // System then assistant — regenerate should refuse because the
        // prior turn isn't a user turn.
        var store = TranscriptStore(entries: [
            TranscriptEntry(role: .system, text: "you are helpful"),
            TranscriptEntry(role: .assistant, text: "stale"),
        ])
        let result = store.regenerate()
        XCTAssertNil(result)
        XCTAssertEqual(store.entries.count, 2)
    }

    // MARK: history snapshot

    func testTurnsForHistoryExcludesSystemTurns() {
        let store = TranscriptStore(entries: [
            TranscriptEntry(role: .system, text: "be brief"),
            TranscriptEntry(role: .user, text: "hi"),
            TranscriptEntry(role: .assistant, text: "hello"),
        ])
        let turns = store.turnsForHistory()
        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(turns.map(\.content), ["hi", "hello"])
    }

    func testTurnsForHistoryPreservesImageURLs() {
        let url = URL(fileURLWithPath: "/tmp/x.png")
        let store = TranscriptStore(entries: [
            TranscriptEntry(role: .user, text: "what is this?", imageURL: url),
        ])
        let turns = store.turnsForHistory()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].imageURLs, [url])
    }

    func testTurnsForHistoryPreservesOrder() {
        var store = TranscriptStore()
        _ = store.appendUser("a")
        let a1 = store.beginAssistant(); store.appendChunk("A", to: a1)
        _ = store.appendUser("b")
        let a2 = store.beginAssistant(); store.appendChunk("B", to: a2)
        let turns = store.turnsForHistory()
        XCTAssertEqual(turns.map(\.content), ["a", "A", "b", "B"])
    }
}
