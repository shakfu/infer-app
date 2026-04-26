import XCTest
@testable import InferAgents

final class MCPProtocolTests: XCTestCase {

    func testRequestEncodesWithIdMethodParams() throws {
        let req = MCP.Request(
            id: 7,
            method: "tools/call",
            params: .object(["name": .string("foo")])
        )
        let data = try JSONEncoder().encode(req)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(obj["id"] as? Int, 7)
        XCTAssertEqual(obj["method"] as? String, "tools/call")
        let params = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(params["name"] as? String, "foo")
    }

    func testRequestOmitsParamsWhenNil() throws {
        let req = MCP.Request(id: 1, method: "tools/list", params: nil)
        let data = try JSONEncoder().encode(req)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(obj["params"], "params key should be absent when nil so server-side schemas accept the call")
    }

    func testNotificationHasNoId() throws {
        let n = MCP.Notification(method: "notifications/initialized")
        let data = try JSONEncoder().encode(n)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(obj["id"])
        XCTAssertEqual(obj["method"] as? String, "notifications/initialized")
    }

    func testResponseDecodesResult() throws {
        let json = #"{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}"#
        let resp = try JSONDecoder().decode(MCP.Response.self, from: Data(json.utf8))
        XCTAssertEqual(resp.id, 3)
        XCTAssertNotNil(resp.result)
        XCTAssertNil(resp.error)
    }

    func testResponseDecodesError() throws {
        let json = #"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"method not found"}}"#
        let resp = try JSONDecoder().decode(MCP.Response.self, from: Data(json.utf8))
        XCTAssertEqual(resp.error?.code, -32601)
        XCTAssertEqual(resp.error?.message, "method not found")
    }

    func testListToolsResultDecodes() throws {
        let json = """
        {"tools":[
          {"name":"echo","description":"echoes","inputSchema":{"type":"object"}},
          {"name":"clock"}
        ]}
        """
        let result = try JSONDecoder().decode(
            MCP.ListToolsResult.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(result.tools.count, 2)
        XCTAssertEqual(result.tools[0].name, "echo")
        XCTAssertEqual(result.tools[0].description, "echoes")
        XCTAssertNotNil(result.tools[0].inputSchema)
        XCTAssertEqual(result.tools[1].name, "clock")
        XCTAssertNil(result.tools[1].description)
    }

    func testCallToolResultPicksTextBlocks() throws {
        let json = """
        {"content":[
          {"type":"text","text":"hello"},
          {"type":"image","data":"…ignored…"},
          {"type":"text","text":"world"}
        ]}
        """
        let result = try JSONDecoder().decode(
            MCP.CallToolResult.self,
            from: Data(json.utf8)
        )
        let texts = (result.content ?? []).compactMap {
            $0.type == "text" ? $0.text : nil
        }
        XCTAssertEqual(texts, ["hello", "world"])
    }

    func testCallToolParamsParsesArgumentsString() throws {
        let p = MCP.CallToolParams(
            name: "tool",
            argumentsJSON: #"{"a":1,"b":"two"}"#
        )
        let data = try JSONEncoder().encode(p)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let args = try XCTUnwrap(obj["arguments"] as? [String: Any])
        XCTAssertEqual(args["a"] as? Int, 1)
        XCTAssertEqual(args["b"] as? String, "two")
    }

    func testCallToolParamsRecoversFromBadJSON() throws {
        let p = MCP.CallToolParams(name: "tool", argumentsJSON: "not json at all")
        let data = try JSONEncoder().encode(p)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let args = try XCTUnwrap(obj["arguments"] as? [String: Any])
        XCTAssertTrue(args.isEmpty, "malformed input falls back to empty object")
    }

    // MARK: - AnyJSON

    func testAnyJSONRoundTripsObject() throws {
        let original: AnyJSON = .object([
            "n": .int(42),
            "s": .string("hi"),
            "arr": .array([.bool(true), .double(3.14), .null]),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyJSON.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testAnyJSONFromAnyCoercesIntegralDoubleToInt() {
        let lifted = AnyJSON.fromAny(7.0)
        if case .int(let v) = lifted {
            XCTAssertEqual(v, 7)
        } else {
            XCTFail("expected .int from a whole-number Double, got \(lifted)")
        }
    }

    func testServerConfigDecodeMinimal() throws {
        let json = #"{"id":"fs-mcp","command":"/usr/local/bin/fs-mcp"}"#
        let cfg = try JSONDecoder().decode(MCPServerConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.id, "fs-mcp")
        XCTAssertEqual(cfg.command, "/usr/local/bin/fs-mcp")
        XCTAssertEqual(cfg.args, [])
        XCTAssertTrue(cfg.enabled, "enabled should default to true")
    }

    func testServerConfigDecodeFull() throws {
        let json = #"""
        {
          "id":"slack",
          "displayName":"Slack",
          "command":"node",
          "args":["/path/to/server.js","--workspace=t"],
          "env":{"TOKEN":"xoxb-…"},
          "enabled":false
        }
        """#
        let cfg = try JSONDecoder().decode(MCPServerConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.id, "slack")
        XCTAssertEqual(cfg.displayName, "Slack")
        XCTAssertEqual(cfg.args, ["/path/to/server.js", "--workspace=t"])
        XCTAssertEqual(cfg.env?["TOKEN"], "xoxb-…")
        XCTAssertFalse(cfg.enabled)
    }
}
