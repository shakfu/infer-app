import XCTest
@testable import InferAgents

final class MCPClientTests: XCTestCase {

    /// Helper: spin up the client, drive the handshake by responding
    /// to its initialize and tools/list requests in order, return the
    /// fully-initialised pair so tests can drive their own scenarios
    /// from a known-good baseline.
    private func bootedClient(
        tools: String = #"{"tools":[{"name":"echo","description":"e"}]}"#
    ) async throws -> (MCPClient, MockMCPTransport) {
        let transport = MockMCPTransport()
        let client = MCPClient(
            serverID: "test",
            displayName: "Test",
            transport: transport,
            requestTimeout: 2
        )
        // Drive the handshake. start() sends initialize then tools/list;
        // we respond to each once we've observed it on the wire.
        let startTask = Task { try await client.start() }
        try await waitForMethod("initialize", on: transport, deadline: 1.0)
        transport.respondResult(id: 1, resultJSON: #"{"protocolVersion":"2025-03-26","serverInfo":{"name":"test","version":"0"}}"#)
        try await waitForMethod("tools/list", on: transport, deadline: 1.0)
        transport.respondResult(id: 2, resultJSON: tools)
        try await startTask.value
        return (client, transport)
    }

    func testStartRunsInitializeThenListTools() async throws {
        let (client, transport) = try await bootedClient()
        let observed = await transport.sentMethods()
        XCTAssertEqual(
            observed,
            ["initialize", "notifications/initialized", "tools/list"]
        )
        let tools = await client.tools()
        XCTAssertEqual(tools.map(\.name), ["echo"])
    }

    func testCallToolReturnsConcatenatedTextContent() async throws {
        let (client, transport) = try await bootedClient()
        let callTask = Task {
            try await client.callTool(name: "echo", argumentsJSON: #"{"x":1}"#)
        }
        try await waitForMethod("tools/call", on: transport, deadline: 1.0)
        // The third request id is 3 (initialize=1, tools/list=2,
        // tools/call=3) — the actor counts up monotonically.
        transport.respondResult(
            id: 3,
            resultJSON: #"{"content":[{"type":"text","text":"hello"},{"type":"text","text":" world"}]}"#
        )
        let text = try await callTask.value
        XCTAssertEqual(text, "hello\n world")
    }

    func testCallToolThrowsOnIsErrorTrue() async throws {
        let (client, transport) = try await bootedClient()
        let callTask = Task {
            try await client.callTool(name: "echo", argumentsJSON: "{}")
        }
        try await waitForMethod("tools/call", on: transport, deadline: 1.0)
        transport.respondResult(
            id: 3,
            resultJSON: #"{"content":[{"type":"text","text":"the file did not exist"}],"isError":true}"#
        )
        do {
            _ = try await callTask.value
            XCTFail("expected throw")
        } catch let MCPError.toolErrored(message) {
            XCTAssertEqual(message, "the file did not exist")
        }
    }

    func testCallToolThrowsOnRpcError() async throws {
        let (client, transport) = try await bootedClient()
        let callTask = Task {
            try await client.callTool(name: "missing", argumentsJSON: "{}")
        }
        try await waitForMethod("tools/call", on: transport, deadline: 1.0)
        transport.respondError(id: 3, code: -32601, message: "no such tool")
        do {
            _ = try await callTask.value
            XCTFail("expected throw")
        } catch let MCPError.rpcError(code, message) {
            XCTAssertEqual(code, -32601)
            XCTAssertEqual(message, "no such tool")
        }
    }

    func testCallBeforeStartFails() async throws {
        let transport = MockMCPTransport()
        let client = MCPClient(
            serverID: "t", displayName: "T", transport: transport
        )
        do {
            _ = try await client.callTool(name: "x", argumentsJSON: "{}")
            XCTFail("expected throw")
        } catch MCPError.notReady {
            // expected
        }
    }

    func testShutdownDrainsPendingWithTransportClosed() async throws {
        let (client, transport) = try await bootedClient()
        let callTask = Task {
            try await client.callTool(name: "echo", argumentsJSON: "{}")
        }
        try await waitForMethod("tools/call", on: transport, deadline: 1.0)
        // Don't respond — shut down instead.
        await client.shutdown()
        do {
            _ = try await callTask.value
            XCTFail("expected throw")
        } catch MCPError.transportClosed {
            // expected
        }
    }

    // MARK: - MCPBuiltinTool adapter

    func testMCPBuiltinToolForwardsAndWrapsErrors() async throws {
        let (client, transport) = try await bootedClient()
        let tools = await client.tools()
        let adapter = MCPBuiltinTool(
            serverID: "test",
            tool: tools[0],
            client: client
        )
        XCTAssertEqual(adapter.name, "mcp.test.echo")

        let invokeTask = Task { try await adapter.invoke(arguments: "{}") }
        try await waitForMethod("tools/call", on: transport, deadline: 1.0)
        transport.respondError(id: 3, code: -32000, message: "server is sad")
        let result = try await invokeTask.value
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(result.error, "mcp rpc: server is sad",
            "RPC errors surface as ToolResult.error so the model sees them as recoverable")
    }

    // MARK: - Helper

    /// Spin until the mock observes a request with `method`. Bounded
    /// by `deadline` seconds so a test bug fails fast instead of
    /// hanging the suite.
    private func waitForMethod(
        _ method: String,
        on transport: MockMCPTransport,
        deadline: TimeInterval
    ) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            let methods = await transport.sentMethods()
            if methods.last == method { return }
            if methods.contains(method) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let methods = await transport.sentMethods()
        XCTFail("timed out waiting for \(method); observed: \(methods)")
    }
}
