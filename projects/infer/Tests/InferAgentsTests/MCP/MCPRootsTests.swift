import XCTest
@testable import InferAgents

final class MCPRootsTests: XCTestCase {

    // MARK: - URI normalisation

    func testNormalizeAbsolutePath() {
        let root = MCPClient.normalizeRoot("/tmp/work")
        XCTAssertTrue(root.uri.hasPrefix("file:///tmp/work"),
            "absolute path should round-trip into a file:// URI; got \(root.uri)")
        XCTAssertEqual(root.name, "work")
    }

    func testNormalizeTildePath() {
        let root = MCPClient.normalizeRoot("~/Documents")
        XCTAssertTrue(root.uri.hasPrefix("file://"))
        XCTAssertTrue(root.uri.contains("/Documents"),
            "tilde should expand into the user's home; got \(root.uri)")
        XCTAssertEqual(root.name, "Documents")
    }

    func testNormalizeAlreadyFileURI() {
        let root = MCPClient.normalizeRoot("file:///opt/data")
        XCTAssertEqual(root.uri, "file:///opt/data")
    }

    // MARK: - Capability advertisement at initialize

    func testInitializeAdvertisesRootsCapabilityWhenConfigured() async throws {
        let transport = MockMCPTransport()
        let client = MCPClient(
            serverID: "test",
            displayName: "Test",
            transport: transport,
            requestTimeout: 2,
            roots: ["/tmp/work"]
        )
        let startTask = Task { try await client.start() }
        // Wait for initialize to land on the wire.
        try await waitForMethod("initialize", on: transport, deadline: 1.0)
        // Inspect the initialize frame for the roots capability.
        let frames = await transport.sentFrames()
        let initFrame = try XCTUnwrap(frames.first)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: initFrame) as? [String: Any]
        )
        let params = try XCTUnwrap(parsed["params"] as? [String: Any])
        let caps = try XCTUnwrap(params["capabilities"] as? [String: Any])
        let roots = try XCTUnwrap(caps["roots"] as? [String: Any])
        XCTAssertEqual(roots["listChanged"] as? Bool, false)

        // Finish the handshake so the start task unwinds.
        transport.respondResult(id: 1, resultJSON: #"{"protocolVersion":"2025-03-26"}"#)
        try await waitForMethod("tools/list", on: transport, deadline: 1.0)
        transport.respondResult(id: 2, resultJSON: #"{"tools":[]}"#)
        try await startTask.value
    }

    func testInitializeOmitsRootsCapabilityWhenEmpty() async throws {
        let transport = MockMCPTransport()
        let client = MCPClient(
            serverID: "test",
            displayName: "Test",
            transport: transport,
            requestTimeout: 2
        )
        let startTask = Task { try await client.start() }
        try await waitForMethod("initialize", on: transport, deadline: 1.0)
        let frames = await transport.sentFrames()
        let initFrame = try XCTUnwrap(frames.first)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: initFrame) as? [String: Any]
        )
        let params = try XCTUnwrap(parsed["params"] as? [String: Any])
        let caps = try XCTUnwrap(params["capabilities"] as? [String: Any])
        XCTAssertNil(caps["roots"], "no roots capability should be advertised when none configured")

        transport.respondResult(id: 1, resultJSON: #"{"protocolVersion":"2025-03-26"}"#)
        try await waitForMethod("tools/list", on: transport, deadline: 1.0)
        transport.respondResult(id: 2, resultJSON: #"{"tools":[]}"#)
        try await startTask.value
    }

    // MARK: - Inbound roots/list request handling

    func testRespondsToInboundRootsListWithConfiguredRoots() async throws {
        let transport = MockMCPTransport()
        let client = MCPClient(
            serverID: "test",
            displayName: "Test",
            transport: transport,
            requestTimeout: 2,
            roots: ["/tmp/alpha", "/tmp/beta"]
        )
        let startTask = Task { try await client.start() }
        try await waitForMethod("initialize", on: transport, deadline: 1.0)
        transport.respondResult(id: 1, resultJSON: #"{"protocolVersion":"2025-03-26"}"#)
        try await waitForMethod("tools/list", on: transport, deadline: 1.0)
        transport.respondResult(id: 2, resultJSON: #"{"tools":[]}"#)
        try await startTask.value

        // Push an inbound roots/list request from the "server".
        let baselineFrames = await transport.sentFrames()
        let baseline = baselineFrames.count
        transport.respond(rawJSON: #"{"jsonrpc":"2.0","id":42,"method":"roots/list"}"#)

        // Wait for the client to reply.
        try await waitUntil(deadline: 1.0) {
            await transport.sentFrames().count > baseline
        }
        let frames = await transport.sentFrames()
        let reply = frames.last!
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        )
        XCTAssertEqual(obj["id"] as? Int, 42)
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let roots = try XCTUnwrap(result["roots"] as? [[String: Any]])
        XCTAssertEqual(roots.count, 2)
        let uris = roots.compactMap { $0["uri"] as? String }
        XCTAssertTrue(uris[0].contains("/tmp/alpha"))
        XCTAssertTrue(uris[1].contains("/tmp/beta"))

        await client.shutdown()
    }

    func testInboundUnknownMethodRepliesMethodNotFound() async throws {
        let transport = MockMCPTransport()
        let client = MCPClient(
            serverID: "test", displayName: "Test", transport: transport,
            requestTimeout: 2
        )
        let startTask = Task { try await client.start() }
        try await waitForMethod("initialize", on: transport, deadline: 1.0)
        transport.respondResult(id: 1, resultJSON: #"{"protocolVersion":"2025-03-26"}"#)
        try await waitForMethod("tools/list", on: transport, deadline: 1.0)
        transport.respondResult(id: 2, resultJSON: #"{"tools":[]}"#)
        try await startTask.value

        let baseline = await transport.sentFrames().count
        transport.respond(rawJSON: #"{"jsonrpc":"2.0","id":99,"method":"sampling/createMessage","params":{}}"#)
        try await waitUntil(deadline: 1.0) {
            await transport.sentFrames().count > baseline
        }
        let reply = await transport.sentFrames().last!
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        )
        let error = try XCTUnwrap(obj["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)

        await client.shutdown()
    }

    // MARK: - Helpers

    private func waitForMethod(
        _ method: String,
        on transport: MockMCPTransport,
        deadline: TimeInterval
    ) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            let methods = await transport.sentMethods()
            if methods.contains(method) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let methods = await transport.sentMethods()
        XCTFail("timed out waiting for \(method); observed: \(methods)")
    }

    private func waitUntil(
        deadline: TimeInterval,
        _ check: () async -> Bool
    ) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            if await check() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("waitUntil timed out")
    }
}
