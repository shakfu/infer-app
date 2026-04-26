import Foundation

/// Adapter that exposes one MCP tool through the existing
/// `BuiltinTool` protocol so the agent layer's `ToolRegistry`,
/// per-agent `toolsAllow` / `toolsDeny`, and the chat-VM tool loop
/// don't need to know MCP exists. From the agent's point of view
/// it's just another tool with a `mcp.<server>.<tool>` name.
///
/// Naming convention: `mcp.` prefix + server id + `.` + raw tool
/// name. The server id is whatever the host registered the
/// `MCPClient` under (a config-file basename, typically). Two
/// servers exposing the same raw tool name namespace cleanly under
/// their server prefix; an agent that wants only the version from
/// one server lists `mcp.fs-readonly.read` in `toolsAllow` and
/// excludes the others.
///
/// Errors: any throw from `MCPClient.callTool` is converted to a
/// `ToolResult(error:)` so the model sees the failure as a normal
/// recoverable tool error (same shape as a builtin tool returning an
/// error). Transport-closed and timeout still surface as text in the
/// error field with a short prefix indicating the source.
public struct MCPBuiltinTool: BuiltinTool {

    public let name: ToolName
    public let serverID: String
    public let rawToolName: String
    public let toolDescription: String
    private let client: MCPClient

    public var spec: ToolSpec {
        ToolSpec(name: name, description: toolDescription)
    }

    public init(serverID: String, tool: MCP.Tool, client: MCPClient) {
        self.serverID = serverID
        self.rawToolName = tool.name
        self.name = "mcp.\(serverID).\(tool.name)"
        self.toolDescription = tool.description ?? "(no description)"
        self.client = client
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        do {
            let text = try await client.callTool(
                name: rawToolName,
                argumentsJSON: arguments
            )
            return ToolResult(output: text)
        } catch let MCPError.toolErrored(message) {
            return ToolResult(output: "", error: message)
        } catch let MCPError.rpcError(_, message) {
            return ToolResult(output: "", error: "mcp rpc: \(message)")
        } catch MCPError.timeout {
            return ToolResult(output: "", error: "mcp timeout (server \(serverID))")
        } catch MCPError.transportClosed {
            return ToolResult(output: "", error: "mcp server closed (\(serverID))")
        } catch {
            return ToolResult(output: "", error: "mcp call failed: \(error)")
        }
    }
}

/// Server config — what to launch and how. JSON-loadable so users can
/// drop a file into `~/Library/Application Support/Infer/mcp/<id>.json`
/// without touching Swift. The `id` is the file basename; the rest of
/// the schema mirrors the Anthropic Desktop format closely enough that
/// users with existing configs only have to copy them over.
public struct MCPServerConfig: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String?
    public let command: String
    public let args: [String]
    public let env: [String: String]?
    /// When false, the host's bootstrap will skip launching this
    /// server. Useful for keeping a config file around while
    /// temporarily disabling it.
    public let enabled: Bool
    /// Skip the consent gate for this server. Set on configs the
    /// user wrote themselves and trusts implicitly (first-party
    /// servers, ones they've vetted). Default false so unknown
    /// servers must go through `MCPApprovalProvider` — that gate is
    /// the point of consent enforcement.
    public let autoApprove: Bool
    /// Filesystem paths the server is allowed to operate on, surfaced
    /// to the server via the MCP `roots` capability. Empty disables
    /// the capability advertisement entirely; the server falls back
    /// to whatever the OS-level subprocess permissions allow (which
    /// is everything the parent process can reach — the reason the
    /// roots advertisement matters in the first place). A
    /// well-behaved server respects the list; non-conformant servers
    /// can ignore it, which is why the consent gate runs first.
    public let roots: [String]

    public init(
        id: String,
        displayName: String? = nil,
        command: String,
        args: [String] = [],
        env: [String: String]? = nil,
        enabled: Bool = true,
        autoApprove: Bool = false,
        roots: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
        self.autoApprove = autoApprove
        self.roots = roots
    }

    /// Decode tolerantly: every field except `id` and `command` is
    /// optional; `enabled` defaults to true so a minimal config (just
    /// id + command) is valid. `autoApprove` and `roots` default to
    /// the safe values (gate enabled, no advertised filesystem
    /// scope).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.command = try c.decode(String.self, forKey: .command)
        self.args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        self.env = try c.decodeIfPresent([String: String].self, forKey: .env)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.autoApprove = try c.decodeIfPresent(Bool.self, forKey: .autoApprove) ?? false
        self.roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? []
    }
}

/// Per-server diagnostics returned by `MCPHost.bootstrap`. Skipped /
/// failed entries don't abort the bootstrap — the host can surface
/// the diagnostic in the Console tab and keep going with the servers
/// that did come up. Mirrors `AgentRegistry.PersonaLoadError` in
/// shape so the same UI renderer works for both.
public struct MCPLoadDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case warning, skipped, error
    }
    public let serverID: String
    public let severity: Severity
    public let message: String

    public init(serverID: String, severity: Severity, message: String) {
        self.serverID = serverID
        self.severity = severity
        self.message = message
    }
}

/// Snapshot of one MCP server's state for the in-app config UI.
/// Captures both the static config (so disabled / pending-approval
/// servers are still visible to the user) and the runtime state
/// (advertised roots, discovered tools) when the server actually
/// launched. Cheap to copy across the actor boundary into the
/// `@MainActor` view-model mirror.
public struct MCPServerSummary: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        /// Subprocess running, tools registered.
        case running
        /// Skipped because the user hasn't approved this server.
        /// `MCPApprovalStore.approve(serverID:)` + reload activates it.
        case denied
        /// Skipped because `enabled: false` in the config file. Edit
        /// the JSON to flip and reload.
        case disabled
        /// Config file failed to decode, subprocess failed to launch,
        /// or the initialize handshake errored. Message carries the
        /// upstream cause.
        case failed(String)
    }

    public let id: String
    public let displayName: String
    public let command: String
    public let autoApprove: Bool
    public let configRoots: [String]
    public let isApproved: Bool
    public let status: Status
    public let advertisedRoots: [MCP.Root]
    public let tools: [MCP.Tool]

    public init(
        id: String,
        displayName: String,
        command: String,
        autoApprove: Bool,
        configRoots: [String],
        isApproved: Bool,
        status: Status,
        advertisedRoots: [MCP.Root] = [],
        tools: [MCP.Tool] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.command = command
        self.autoApprove = autoApprove
        self.configRoots = configRoots
        self.isApproved = isApproved
        self.status = status
        self.advertisedRoots = advertisedRoots
        self.tools = tools
    }
}

/// Owns the running `MCPClient`s, registers their tools into a
/// `ToolRegistry`, and drives lifecycle (bootstrap on app start,
/// shutdown on app terminate). One `MCPHost` per app.
///
/// Server discovery: scan a directory for `*.json` config files,
/// decode each via `MCPServerConfig`, launch a subprocess per
/// enabled config, run `initialize` + `tools/list`, register one
/// `MCPBuiltinTool` per discovered tool. Failures (file decode,
/// subprocess launch, initialize timeout) are collected as
/// diagnostics; the rest of the bootstrap continues.
public actor MCPHost {

    public private(set) var clients: [String: MCPClient] = [:]
    public private(set) var diagnostics: [MCPLoadDiagnostic] = []
    public private(set) var summaries: [MCPServerSummary] = []
    /// Backing store for per-server consent decisions. Held here so
    /// the host's `approve` / `revoke` methods land in the same place
    /// the default approval provider reads, and so a fresh `MCPHost`
    /// instance constructed for tests can inject a per-test store
    /// without touching `UserDefaults.standard`.
    public let approvalStore: MCPApprovalStore

    public init(approvalStore: MCPApprovalStore = MCPApprovalStore()) {
        self.approvalStore = approvalStore
    }

    /// Discover and launch servers from `directory`, register their
    /// tools into `registry`. Returns the per-server diagnostics so
    /// the host can surface them.
    ///
    /// `approvalProvider` runs once per discovered enabled server
    /// (after `autoApprove` short-circuit, before subprocess launch).
    /// Default deny-all behaviour means a fresh install with no
    /// stored approvals will skip every server with a clear
    /// diagnostic — the user has to opt in either by setting
    /// `autoApprove: true` in the config or by approving through a
    /// host-supplied UI that calls `MCPApprovalStore.approve`.
    @discardableResult
    public func bootstrap(
        directory: URL,
        into registry: ToolRegistry,
        clientName: String = "infer",
        clientVersion: String = "0.0.0",
        stderrSink: StdioMCPTransport.StderrSink? = nil,
        approvalProvider: MCPApprovalProvider? = nil
    ) async -> [MCPLoadDiagnostic] {
        let provider = approvalProvider
            ?? defaultMCPApprovalProvider(store: approvalStore)
        var collected: [MCPLoadDiagnostic] = []
        var summaries: [MCPServerSummary] = []
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            // Missing directory is fine — the user just hasn't
            // configured any servers. No diagnostic.
            self.summaries = []
            self.diagnostics = []
            return []
        }
        let jsons = urls.filter { $0.pathExtension.lowercased() == "json" }
        for url in jsons {
            let id = url.deletingPathExtension().lastPathComponent
            do {
                let data = try Data(contentsOf: url)
                let config = try JSONDecoder().decode(MCPServerConfig.self, from: data)
                let approved = approvalStore.isApproved(serverID: config.id)
                guard config.enabled else {
                    collected.append(MCPLoadDiagnostic(
                        serverID: config.id,
                        severity: .skipped,
                        message: "disabled in config"
                    ))
                    summaries.append(MCPServerSummary(
                        id: config.id,
                        displayName: config.displayName ?? config.id,
                        command: config.command,
                        autoApprove: config.autoApprove,
                        configRoots: config.roots,
                        isApproved: approved,
                        status: .disabled
                    ))
                    continue
                }
                let decision = await provider(config)
                guard decision != .deny else {
                    collected.append(MCPLoadDiagnostic(
                        serverID: config.id,
                        severity: .skipped,
                        message: "consent required — approve in the Agents tab, or set autoApprove:true in the config"
                    ))
                    summaries.append(MCPServerSummary(
                        id: config.id,
                        displayName: config.displayName ?? config.id,
                        command: config.command,
                        autoApprove: config.autoApprove,
                        configRoots: config.roots,
                        isApproved: approved,
                        status: .denied
                    ))
                    continue
                }
                let summary = await launch(
                    config: config,
                    into: registry,
                    clientName: clientName,
                    clientVersion: clientVersion,
                    stderrSink: stderrSink,
                    isApproved: approved,
                    collected: &collected
                )
                summaries.append(summary)
            } catch {
                collected.append(MCPLoadDiagnostic(
                    serverID: id,
                    severity: .error,
                    message: "config load failed: \(error)"
                ))
                summaries.append(MCPServerSummary(
                    id: id,
                    displayName: id,
                    command: "(unparseable)",
                    autoApprove: false,
                    configRoots: [],
                    isApproved: approvalStore.isApproved(serverID: id),
                    status: .failed("config load failed: \(error.localizedDescription)")
                ))
            }
        }
        diagnostics = collected
        self.summaries = summaries.sorted { $0.id < $1.id }
        return collected
    }

    /// Approve a server through the host's store. The change persists
    /// via `MCPApprovalStore`; call `reload(...)` afterward to actually
    /// (re)launch the now-approved server. Splitting approval from
    /// reload lets a UI batch multiple approvals before re-running
    /// bootstrap once.
    public func approve(serverID: String) {
        approvalStore.approve(serverID: serverID)
    }

    /// Revoke approval. Call `reload(...)` afterward to shut down the
    /// running client and unregister its tools. Like `approve`, a
    /// no-op on the registry until reload.
    public func revoke(serverID: String) {
        approvalStore.revoke(serverID: serverID)
    }

    /// Tear down all running clients, unregister their tools from
    /// `registry`, then re-run `bootstrap`. Used by the in-app UI
    /// after the user toggles approvals or edits a config file.
    /// Per-server tool unregistration is by `mcp.<id>.` prefix so a
    /// previously-launched-now-revoked server's tools disappear from
    /// the agent layer instead of lingering until app restart.
    @discardableResult
    public func reload(
        directory: URL,
        into registry: ToolRegistry,
        clientName: String = "infer",
        clientVersion: String = "0.0.0",
        stderrSink: StdioMCPTransport.StderrSink? = nil,
        approvalProvider: MCPApprovalProvider? = nil
    ) async -> [MCPLoadDiagnostic] {
        for (serverID, client) in clients {
            await client.shutdown()
            await registry.unregister(prefixed: "mcp.\(serverID).")
        }
        clients.removeAll()
        return await bootstrap(
            directory: directory,
            into: registry,
            clientName: clientName,
            clientVersion: clientVersion,
            stderrSink: stderrSink,
            approvalProvider: approvalProvider
        )
    }

    /// Launch a single configured server. Public so a host can wire
    /// servers from a non-file source (e.g. an in-memory list for
    /// tests, or a UI-driven add). Same diagnostic protocol as
    /// `bootstrap`.
    @discardableResult
    public func launch(
        config: MCPServerConfig,
        into registry: ToolRegistry,
        clientName: String = "infer",
        clientVersion: String = "0.0.0",
        stderrSink: StdioMCPTransport.StderrSink? = nil,
        isApproved: Bool = false,
        collected: inout [MCPLoadDiagnostic]
    ) async -> MCPServerSummary {
        let executable = MCPHost.resolveExecutable(config.command)
        let transport: StdioMCPTransport
        do {
            transport = try StdioMCPTransport(
                executable: executable,
                arguments: config.args,
                environment: config.env,
                stderrSink: stderrSink
            )
        } catch {
            let msg = "launch failed: \(error)"
            collected.append(MCPLoadDiagnostic(
                serverID: config.id, severity: .error, message: msg
            ))
            return summary(for: config, isApproved: isApproved, status: .failed(msg))
        }
        let client = MCPClient(
            serverID: config.id,
            displayName: config.displayName ?? config.id,
            transport: transport,
            roots: config.roots
        )
        do {
            try await client.start(clientName: clientName, clientVersion: clientVersion)
        } catch {
            await client.shutdown()
            let msg = "initialize failed: \(error)"
            collected.append(MCPLoadDiagnostic(
                serverID: config.id, severity: .error, message: msg
            ))
            return summary(for: config, isApproved: isApproved, status: .failed(msg))
        }
        let tools = await client.tools()
        if tools.isEmpty {
            collected.append(MCPLoadDiagnostic(
                serverID: config.id,
                severity: .warning,
                message: "server initialized but exposed no tools"
            ))
        }
        // Surface the granted filesystem scope so the user can see
        // what the server is allowed to reach (only meaningful when
        // the server actually honors the advertised roots — non-
        // conformant servers ignore them, which is why the consent
        // gate runs first).
        let resolvedRoots = await client.configuredRoots()
        if !resolvedRoots.isEmpty {
            let scope = resolvedRoots.map { $0.uri }.joined(separator: ", ")
            collected.append(MCPLoadDiagnostic(
                serverID: config.id,
                severity: .warning,
                message: "advertised roots: \(scope)"
            ))
        }
        clients[config.id] = client
        let adapters: [any BuiltinTool] = tools.map {
            MCPBuiltinTool(serverID: config.id, tool: $0, client: client)
        }
        await registry.register(adapters)
        return MCPServerSummary(
            id: config.id,
            displayName: config.displayName ?? config.id,
            command: config.command,
            autoApprove: config.autoApprove,
            configRoots: config.roots,
            isApproved: isApproved,
            status: .running,
            advertisedRoots: resolvedRoots,
            tools: tools
        )
    }

    private func summary(
        for config: MCPServerConfig,
        isApproved: Bool,
        status: MCPServerSummary.Status
    ) -> MCPServerSummary {
        MCPServerSummary(
            id: config.id,
            displayName: config.displayName ?? config.id,
            command: config.command,
            autoApprove: config.autoApprove,
            configRoots: config.roots,
            isApproved: isApproved,
            status: status
        )
    }

    /// Tear down every running server. Called from app shutdown.
    public func shutdown() async {
        for (_, client) in clients {
            await client.shutdown()
        }
        clients.removeAll()
    }

    /// Resolve a `command` string into an executable URL. Absolute
    /// paths are used as-is; bare names are looked up in PATH via
    /// `/usr/bin/env`-style search. Falls back to treating the input
    /// as an absolute path so `Process.run()` produces a clear
    /// "no such file" error rather than a confusing PATH miss.
    static func resolveExecutable(_ command: String) -> URL {
        if command.hasPrefix("/") {
            return URL(fileURLWithPath: command)
        }
        // Search PATH manually so we surface a missing binary as a
        // launch failure, not a confusing "/usr/bin/env: <name>" exit
        // from the child.
        let fm = FileManager.default
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir))
                .appendingPathComponent(command)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: command)
    }
}
