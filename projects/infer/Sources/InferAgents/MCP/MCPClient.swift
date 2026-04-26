import Foundation

/// Actor-isolated client for one MCP server. Owns:
///
///   - one `MCPTransport` (NDJSON stdio in production, mock in tests)
///   - the JSON-RPC request id counter
///   - a table of in-flight requests keyed by id (continuations
///     resumed when the matching response arrives)
///   - a background reader task that pulls frames from the transport
///     and dispatches them to the right continuation
///   - the cached `tools/list` result, refreshed on demand
///
/// Lifecycle: `init` → `start()` (which runs `initialize` + collects
/// the first tool list) → many `callTool` calls → `shutdown()`. Calls
/// before `start()` throw `.notReady`; calls after `shutdown()` throw
/// `.transportClosed`.
///
/// Failure model: transport-level errors (subprocess died mid-call,
/// JSON parse failure on a frame) propagate as throws. Tool-level
/// errors (server returned `isError: true`, or an RPC error object)
/// are still throws but with structured cases — `MCPError.toolErrored`
/// vs `.rpcError` — so the bridge in `MCPBuiltinTool` can decide
/// whether to surface them as a `ToolResult(error:)` (recoverable
/// from the model's perspective) vs propagate up the stack.
public actor MCPClient {

    public let serverID: String
    public let displayName: String
    private let transport: any MCPTransport
    private let requestTimeout: TimeInterval

    /// Pending requests waiting on a response. Keyed by JSON-RPC id.
    /// The continuation resumes with the raw response when it arrives,
    /// or throws on timeout / transport close.
    private var pending: [Int: CheckedContinuation<MCP.Response, Error>] = [:]
    private var nextRequestId: Int = 1
    private var started: Bool = false
    private var didShutdown: Bool = false
    private var cachedTools: [MCP.Tool] = []
    private var readerTask: Task<Void, Never>?

    public init(
        serverID: String,
        displayName: String,
        transport: any MCPTransport,
        requestTimeout: TimeInterval = 30
    ) {
        self.serverID = serverID
        self.displayName = displayName
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    /// Drive the `initialize` handshake, send `notifications/initialized`,
    /// and prime the cached tool list. Idempotent — second calls are
    /// no-ops so a host that retries on a flake doesn't double-init.
    public func start(
        clientName: String = "infer",
        clientVersion: String = "0.0.0"
    ) async throws {
        guard !started else { return }
        guard !didShutdown else {
            throw MCPError.notReady("client already shut down")
        }
        startReaderIfNeeded()

        let initParams = MCP.InitializeParams(
            protocolVersion: "2025-03-26",
            capabilities: MCP.ClientCapabilities(),
            clientInfo: MCP.ClientInfo(name: clientName, version: clientVersion)
        )
        let initData = try JSONEncoder().encode(initParams)
        let initJSON = try JSONDecoder().decode(AnyJSON.self, from: initData)
        let initResp = try await sendRequest(method: "initialize", params: initJSON)
        if let err = initResp.error {
            throw MCPError.rpcError(code: err.code, message: err.message)
        }
        // Notify the server we're ready. Failure here is non-fatal:
        // the spec says clients SHOULD send it, but most servers
        // tolerate its absence.
        let initialized = MCP.Notification(method: "notifications/initialized")
        if let frame = try? JSONEncoder().encode(initialized) {
            try? await transport.send(frame)
        }
        started = true

        // Prime tool catalog. Done at start so the caller sees the
        // tool list synchronously after `start()` returns; subsequent
        // changes can be picked up via `refreshTools()`.
        try await refreshTools()
    }

    /// Re-fetch the server's tool list. Called automatically at
    /// `start()`; callers can re-invoke when a `tools/list_changed`
    /// notification arrives (we don't subscribe in v1, but the hook
    /// is here for the host to drive on a timer or user action).
    @discardableResult
    public func refreshTools() async throws -> [MCP.Tool] {
        let resp = try await sendRequest(method: "tools/list", params: nil)
        if let err = resp.error {
            throw MCPError.rpcError(code: err.code, message: err.message)
        }
        guard let result = resp.result else {
            cachedTools = []
            return []
        }
        let data = try JSONEncoder().encode(result)
        let listed = try JSONDecoder().decode(MCP.ListToolsResult.self, from: data)
        cachedTools = listed.tools
        return listed.tools
    }

    /// Snapshot of the most recent `tools/list` result. Synchronous —
    /// the catalog is cached on the actor.
    public func tools() -> [MCP.Tool] { cachedTools }

    /// Invoke `tool` with `argumentsJSON` (the agent layer's raw
    /// JSON-string arguments). Returns the concatenated text content
    /// from the server's `content` array. Throws on transport error,
    /// RPC error, or if the server signalled `isError: true`.
    public func callTool(name: String, argumentsJSON: String) async throws -> String {
        guard started else { throw MCPError.notReady("call before start()") }
        let params = MCP.CallToolParams(name: name, argumentsJSON: argumentsJSON)
        let data = try JSONEncoder().encode(params)
        let paramsJSON = try JSONDecoder().decode(AnyJSON.self, from: data)
        let resp = try await sendRequest(method: "tools/call", params: paramsJSON)
        if let err = resp.error {
            throw MCPError.rpcError(code: err.code, message: err.message)
        }
        guard let result = resp.result else { return "" }
        let resultData = try JSONEncoder().encode(result)
        let parsed = try JSONDecoder().decode(MCP.CallToolResult.self, from: resultData)
        let text = (parsed.content ?? []).compactMap { block in
            block.type == "text" ? block.text : nil
        }.joined(separator: "\n")
        if parsed.isError == true {
            throw MCPError.toolErrored(text.isEmpty ? "tool reported error" : text)
        }
        return text
    }

    /// Tear down: cancel the reader task, drain pending requests with
    /// `transportClosed`, terminate the subprocess. Idempotent.
    public func shutdown() async {
        guard !didShutdown else { return }
        didShutdown = true
        readerTask?.cancel()
        readerTask = nil
        for (_, cont) in pending {
            cont.resume(throwing: MCPError.transportClosed)
        }
        pending.removeAll()
        await transport.shutdown()
    }

    // MARK: - Request plumbing

    private func sendRequest(method: String, params: AnyJSON?) async throws -> MCP.Response {
        guard !didShutdown else { throw MCPError.transportClosed }
        let id = nextRequestId
        nextRequestId += 1
        let request = MCP.Request(id: id, method: method, params: params)
        let frame: Data
        do {
            frame = try JSONEncoder().encode(request)
        } catch {
            throw MCPError.decodingFailed("encode request: \(error)")
        }

        // Race the response against a timeout. Pending continuation
        // is registered before send so an immediate server reply
        // can't race ahead of registration.
        return try await withThrowingTaskGroup(of: MCP.Response.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.registerPending(id: id, continuation: cont) }
                    Task {
                        do { try await self.transport.send(frame) }
                        catch { await self.failPending(id: id, error: error) }
                    }
                }
            }
            group.addTask { [requestTimeout] in
                try await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000))
                throw MCPError.timeout
            }
            // First task to finish wins; cancel the rest.
            let result = try await group.next()!
            group.cancelAll()
            // If the timeout fired, drop the pending entry so a late
            // response doesn't crash on missing continuation.
            await self.dropPending(id: id)
            return result
        }
    }

    private func registerPending(id: Int, continuation: CheckedContinuation<MCP.Response, Error>) {
        pending[id] = continuation
    }

    private func failPending(id: Int, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func dropPending(id: Int) {
        pending.removeValue(forKey: id)
    }

    private func deliver(_ response: MCP.Response) {
        guard let id = response.id, let cont = pending.removeValue(forKey: id) else {
            // Notification or unmatched response — ignore for v1.
            return
        }
        cont.resume(returning: response)
    }

    private func failAllPending(error: Error) {
        for (_, cont) in pending {
            cont.resume(throwing: error)
        }
        pending.removeAll()
    }

    private func startReaderIfNeeded() {
        guard readerTask == nil else { return }
        let stream = transport.messages
        readerTask = Task { [weak self] in
            do {
                for try await frame in stream {
                    guard let self else { return }
                    if let response = try? JSONDecoder().decode(MCP.Response.self, from: frame),
                       response.id != nil {
                        await self.deliver(response)
                    }
                    // Notifications (no id) are ignored in v1; later
                    // versions can decode `notifications/tools/list_changed`
                    // and trigger refreshTools.
                }
                await self?.failAllPending(error: MCPError.transportClosed)
            } catch {
                await self?.failAllPending(error: error)
            }
        }
    }
}
