import XCTest
@testable import InferAgents

final class AgentListingTests: XCTestCase {
    func testSimpleNameLowercasedAndHyphenated() {
        XCTAssertEqual(
            AgentListing.makeDisplayLabel(from: "Code Helper", fallbackId: "x"),
            "code-helper"
        )
    }

    func testCollapsesMultipleSeparatorsAndPunctuation() {
        XCTAssertEqual(
            AgentListing.makeDisplayLabel(from: "Code   Helper!!", fallbackId: "x"),
            "code-helper"
        )
        XCTAssertEqual(
            AgentListing.makeDisplayLabel(from: "---leading--and--trailing---", fallbackId: "x"),
            "leading-and-trailing"
        )
    }

    func testAlphanumericSingleToken() {
        XCTAssertEqual(
            AgentListing.makeDisplayLabel(from: "GPT4Turbo", fallbackId: "x"),
            "gpt4turbo"
        )
    }

    func testPreservesCJKAsAlphanumericTokens() {
        XCTAssertEqual(
            AgentListing.makeDisplayLabel(from: "日本語 アシスタント", fallbackId: "x"),
            "日本語-アシスタント"
        )
    }

    func testEmojiOnlyFallsBackToId() {
        XCTAssertEqual(
            AgentListing.makeDisplayLabel(from: "🚀🎯", fallbackId: "rocket.agent"),
            "rocket.agent"
        )
    }

    func testEmptyNameFallsBackToId() {
        XCTAssertEqual(
            AgentListing.makeDisplayLabel(from: "", fallbackId: "fallback"),
            "fallback"
        )
    }

    func testEmojiMixedWithAlphaStripsEmoji() {
        XCTAssertEqual(
            AgentListing.makeDisplayLabel(from: "🚀 rocket bot", fallbackId: "x"),
            "rocket-bot"
        )
    }

    func testInitPopulatesDisplayLabel() {
        let l = AgentListing(
            id: "some.id",
            name: "Docs Writer",
            description: "",
            source: .user,
            backend: .any,
            templateFamily: nil,
            isDefault: false
        )
        XCTAssertEqual(l.displayLabel, "docs-writer")
    }
}
