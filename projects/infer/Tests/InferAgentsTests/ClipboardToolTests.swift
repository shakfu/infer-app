import XCTest
import AppKit
@testable import InferAgents

final class ClipboardToolTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        // Private pasteboard so the tests don't read or write the
        // user's actual clipboard. `NSPasteboard(name:)` returns a
        // distinct pasteboard per name — passing a UUID guarantees
        // isolation between concurrent test invocations too.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("infer.test.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard?.releaseGlobally()
        super.tearDown()
    }

    // MARK: - get

    func testGetReturnsCurrentClipboardText() async throws {
        pasteboard.clearContents()
        pasteboard.setString("on the board", forType: .string)
        let tool = ClipboardGetTool(pasteboard: pasteboard)
        let result = try await tool.invoke(arguments: "{}")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "on the board")
    }

    func testGetReturnsEmptyStringWhenClipboardIsNotText() async throws {
        pasteboard.clearContents()
        // A non-string representation: an arbitrary data blob under a
        // private type. The pasteboard has no `.string` flavour, so
        // get should return an empty string (not error).
        pasteboard.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("infer.test.binary"))
        let tool = ClipboardGetTool(pasteboard: pasteboard)
        let result = try await tool.invoke(arguments: "{}")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "")
    }

    func testGetIgnoresArguments() async throws {
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        let tool = ClipboardGetTool(pasteboard: pasteboard)
        // Tool should not error on unexpected args.
        let result = try await tool.invoke(arguments: #"{"unexpected": "field"}"#)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "hello")
    }

    // MARK: - set

    func testSetReplacesClipboardText() async throws {
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        let tool = ClipboardSetTool(pasteboard: pasteboard)
        let result = try await tool.invoke(arguments: ##"{"text": "new value"}"##)
        XCTAssertNil(result.error)
        XCTAssertEqual(pasteboard.string(forType: .string), "new value")
        XCTAssertTrue(result.output.contains("9 bytes"))
    }

    func testSetClearsPriorRepresentations() async throws {
        // Put both a string and a non-string flavour on first, confirm
        // set replaces both.
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        pasteboard.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("infer.test.binary"))
        let tool = ClipboardSetTool(pasteboard: pasteboard)
        _ = try await tool.invoke(arguments: ##"{"text": "fresh"}"##)
        XCTAssertEqual(pasteboard.string(forType: .string), "fresh")
        XCTAssertNil(pasteboard.data(forType: NSPasteboard.PasteboardType("infer.test.binary")),
                     "set should clear non-string representations too")
    }

    func testSetRejectsMalformedJSON() async throws {
        let tool = ClipboardSetTool(pasteboard: pasteboard)
        let result = try await tool.invoke(arguments: "not-json")
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
    }

    func testSetRejectsOversizeContent() async throws {
        let tool = ClipboardSetTool(pasteboard: pasteboard)
        let oversize = String(repeating: "a", count: ClipboardSetTool.maxBytes + 1)
        let payload: [String: Any] = ["text": oversize]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let result = try await tool.invoke(arguments: String(decoding: data, as: UTF8.self))
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("exceeds"))
    }

    // MARK: - Round-trip

    func testRoundTripSetThenGet() async throws {
        let setTool = ClipboardSetTool(pasteboard: pasteboard)
        let getTool = ClipboardGetTool(pasteboard: pasteboard)
        _ = try await setTool.invoke(arguments: ##"{"text": "round trip"}"##)
        let result = try await getTool.invoke(arguments: "{}")
        XCTAssertEqual(result.output, "round trip")
    }
}
