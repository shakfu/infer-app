import XCTest
@testable import InferAgents

final class ToolCallParserTests: XCTestCase {
    private let parser = ToolCallParser(family: .llama3)

    func testDetectsBasicCallWithEomTerminator() {
        let stream = #"Let me check the time.<|python_tag|>{"name": "builtin.clock.now", "parameters": {}}<|eom_id|>"#
        let match = parser.findFirstCall(in: stream)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.prefix, "Let me check the time.")
        XCTAssertEqual(match?.call.name, "builtin.clock.now")
        XCTAssertEqual(match?.call.arguments, "{}")
    }

    func testDetectsCallWithEotTerminator() {
        let stream = #"<|python_tag|>{"name": "x", "parameters": {}}<|eot_id|>"#
        let match = parser.findFirstCall(in: stream)
        XCTAssertEqual(match?.call.name, "x")
    }

    func testParsesParametersPayload() {
        let stream = #"<|python_tag|>{"name": "builtin.text.wordcount", "parameters": {"text": "hello world"}}<|eom_id|>"#
        let match = parser.findFirstCall(in: stream)
        XCTAssertEqual(match?.call.name, "builtin.text.wordcount")
        // Arguments are re-serialised with sorted keys for determinism.
        XCTAssertEqual(match?.call.arguments, #"{"text":"hello world"}"#)
    }

    func testNoTagReturnsNil() {
        let stream = "plain assistant reply with no tool call"
        XCTAssertNil(parser.findFirstCall(in: stream))
    }

    func testPartialTagBeforeJsonReturnsNil() {
        let stream = "<|python_tag|>"
        XCTAssertNil(parser.findFirstCall(in: stream))
    }

    func testIncompleteJsonBeforeTerminatorReturnsNil() {
        // Stream still being generated; JSON is mid-flight.
        let stream = #"<|python_tag|>{"name": "x", "parameters": {"te"#
        XCTAssertNil(parser.findFirstCall(in: stream))
    }

    func testMalformedJsonReturnsNil() {
        let stream = #"<|python_tag|>not json at all<|eom_id|>"#
        XCTAssertNil(parser.findFirstCall(in: stream))
    }

    func testMissingNameReturnsNil() {
        let stream = #"<|python_tag|>{"parameters": {}}<|eom_id|>"#
        XCTAssertNil(parser.findFirstCall(in: stream))
    }

    func testEmptyNameReturnsNil() {
        let stream = #"<|python_tag|>{"name": "", "parameters": {}}<|eom_id|>"#
        XCTAssertNil(parser.findFirstCall(in: stream))
    }

    func testMissingParametersDefaultsToEmptyObject() {
        let stream = #"<|python_tag|>{"name": "x"}<|eom_id|>"#
        let match = parser.findFirstCall(in: stream)
        XCTAssertEqual(match?.call.arguments, "{}")
    }

    func testTerminatedByEitherTerminatorPrefersEarliest() {
        // Eom appears before eot — parser must not swallow past eom.
        let stream = #"<|python_tag|>{"name": "a", "parameters": {}}<|eom_id|> and then <|eot_id|>"#
        let match = parser.findFirstCall(in: stream)
        XCTAssertEqual(match?.call.name, "a")
    }

    func testPrefixPreservesWhitespace() {
        let stream = "before\n\n<|python_tag|>{\"name\": \"x\"}<|eom_id|>"
        let match = parser.findFirstCall(in: stream)
        XCTAssertEqual(match?.prefix, "before\n\n")
    }

    func testWellFormedCallWithoutTerminator() {
        // Upstream stop-token may have been consumed. As long as the
        // JSON is parseable, we match on EOS.
        let stream = #"<|python_tag|>{"name": "x", "parameters": {}}"#
        XCTAssertEqual(parser.findFirstCall(in: stream)?.call.name, "x")
    }

    func testOnlyFirstCallReturned() {
        // Two calls in one stream — PR 2's loop handles one per turn,
        // so the parser reports the earliest.
        let stream = #"<|python_tag|>{"name": "first", "parameters": {}}<|eom_id|><|python_tag|>{"name": "second", "parameters": {}}<|eom_id|>"#
        let match = parser.findFirstCall(in: stream)
        XCTAssertEqual(match?.call.name, "first")
    }

    // MARK: - Qwen / Hermes (M4)

    func testQwenBasicCall() {
        let p = ToolCallParser(family: .qwen)
        let stream = #"Let me check.<tool_call>{"name": "builtin.clock.now", "arguments": {}}</tool_call>"#
        let match = p.findFirstCall(in: stream)
        XCTAssertEqual(match?.prefix, "Let me check.")
        XCTAssertEqual(match?.call.name, "builtin.clock.now")
        XCTAssertEqual(match?.call.arguments, "{}")
    }

    func testQwenArgumentsKeyAccepted() {
        let p = ToolCallParser(family: .qwen)
        let stream = #"<tool_call>{"name": "builtin.text.wordcount", "arguments": {"text": "hi there"}}</tool_call>"#
        let match = p.findFirstCall(in: stream)
        // Keys re-serialised sorted for determinism.
        XCTAssertEqual(match?.call.arguments, #"{"text":"hi there"}"#)
    }

    func testQwenStringifiedArgumentsNormalised() {
        // Some Hermes variants emit `arguments` as a stringified JSON.
        // Parser unwraps it and re-serialises so the rest of the loop
        // sees the same compact form regardless of source shape.
        let p = ToolCallParser(family: .hermes)
        let stream = #"<tool_call>{"name": "x", "arguments": "{\"a\":1}"}</tool_call>"#
        let match = p.findFirstCall(in: stream)
        XCTAssertEqual(match?.call.arguments, #"{"a":1}"#)
    }

    func testQwenFallsBackToParametersKey() {
        // A model that emits the Llama-style `parameters` wrapper inside
        // `<tool_call>` should still parse — the loop tolerates the
        // wrong wrapper choice rather than dropping the call.
        let p = ToolCallParser(family: .qwen)
        let stream = #"<tool_call>{"name": "x", "parameters": {"k": 1}}</tool_call>"#
        let match = p.findFirstCall(in: stream)
        XCTAssertEqual(match?.call.arguments, #"{"k":1}"#)
    }

    func testQwenIncompleteTagReturnsNil() {
        // Open tag + body, no close yet — caller waits for more tokens.
        let p = ToolCallParser(family: .qwen)
        let stream = #"<tool_call>{"name": "x", "arguments":"#
        XCTAssertNil(p.findFirstCall(in: stream))
    }

    func testQwenNoTagReturnsNil() {
        let p = ToolCallParser(family: .qwen)
        XCTAssertNil(p.findFirstCall(in: "Just a plain reply, no tool."))
    }

    func testHermesUsesSameParser() {
        // Hermes-3 emits the same `<tool_call>` shape; verify the family
        // routes to the same handler. (If they diverge later, this test
        // fails first.)
        let p = ToolCallParser(family: .hermes)
        let stream = #"<tool_call>{"name": "h", "arguments": {}}</tool_call>"#
        XCTAssertEqual(p.findFirstCall(in: stream)?.call.name, "h")
    }

    // MARK: - Family bridge

    func testFamilyBridgeFromTemplateFamily() {
        XCTAssertEqual(ToolCallParser.Family(.llama3), .llama3)
        XCTAssertEqual(ToolCallParser.Family(.qwen), .qwen)
        XCTAssertEqual(ToolCallParser.Family(.hermes), .hermes)
        // OpenAI has no in-stream syntax; bridge to Llama 3.
        XCTAssertEqual(ToolCallParser.Family(.openai), .llama3)
    }
}
