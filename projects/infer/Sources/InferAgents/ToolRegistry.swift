import Foundation

/// A native Swift tool exposed to agents via the `ToolRegistry`. Kept
/// narrow on purpose so a future MCP client can be added alongside
/// without pulling MCP machinery into agents that only need in-process
/// tools. See `docs/dev/plugins.md` for the eventual MCP boundary.
public protocol BuiltinTool: Sendable {
    /// Stable dot-namespaced name, e.g. `builtin.clock.now`. Used as
    /// the registry key and shown to the model in the tool list.
    var name: ToolName { get }

    /// Metadata handed to the agent layer for assembly into the
    /// system-prompt tool section. The `description` should include
    /// enough guidance for the model to know when to call the tool and
    /// what JSON to pass in the `parameters` object.
    var spec: ToolSpec { get }

    /// Run the tool. `arguments` is a raw JSON string (the `parameters`
    /// object from the model's tool call). Implementations are
    /// responsible for decoding. Return `ToolResult(output:)` on
    /// success or `ToolResult(output: "", error:)` on a caught failure
    /// — throwing is reserved for programmer errors the loop should
    /// treat as fatal, not for tool-side errors that the model should
    /// see and recover from.
    func invoke(arguments: String) async throws -> ToolResult
}

public enum ToolError: Error, Equatable, Sendable {
    /// The loop tried to invoke a tool the registry doesn't know. This
    /// is a loop-level invariant violation, not a tool-side error.
    case unknown(ToolName)
}

/// Actor-isolated catalog of locally-registered tools. Per-turn, the
/// agent's `toolsAvailable` hook filters this set; the loop invokes
/// matched calls through `invoke(name:arguments:)`.
public actor ToolRegistry {
    private var tools: [ToolName: any BuiltinTool] = [:]

    public init() {}

    public func register(_ tool: any BuiltinTool) {
        tools[tool.name] = tool
    }

    public func register(_ tools: [any BuiltinTool]) {
        for tool in tools { register(tool) }
    }

    /// Remove one tool by exact name. No-op when the tool isn't
    /// registered. Used by the MCP host on reload / revocation so a
    /// previously-launched server's tools don't linger after the
    /// user removes its approval.
    public func unregister(name: ToolName) {
        tools.removeValue(forKey: name)
    }

    /// Remove every tool whose name starts with `prefix`. Convenience
    /// for the MCP layer, which namespaces all of one server's tools
    /// under `mcp.<serverID>.` — one call sweeps a whole server's
    /// surface in a single mutation. Returns the names that were
    /// removed so callers can log / surface them.
    @discardableResult
    public func unregister(prefixed prefix: String) -> [ToolName] {
        let removed = tools.keys.filter { $0.hasPrefix(prefix) }
        for name in removed { tools.removeValue(forKey: name) }
        return removed
    }

    public func tool(named name: ToolName) -> (any BuiltinTool)? {
        tools[name]
    }

    public func allSpecs() -> [ToolSpec] {
        tools.values
            .map(\.spec)
            .sorted { $0.name < $1.name }
    }

    public func allNames() -> [ToolName] {
        tools.keys.sorted()
    }

    /// Invoke a tool by name. Throws `ToolError.unknown` when the tool
    /// isn't registered; otherwise propagates whatever the tool's
    /// `invoke` throws.
    public func invoke(name: ToolName, arguments: String) async throws -> ToolResult {
        guard let tool = tools[name] else { throw ToolError.unknown(name) }
        return try await tool.invoke(arguments: arguments)
    }

    /// Streaming counterpart to `invoke`. If the named tool conforms to
    /// `StreamingBuiltinTool`, its native streaming path is used. For
    /// plain `BuiltinTool` adopters, the simple `invoke` is wrapped in a
    /// single-event stream so the caller's drain logic is uniform.
    ///
    /// Unknown tool names yield a stream that terminates immediately
    /// with `ToolError.unknown` — symmetric with `invoke(name:)`'s throw,
    /// surfaced as a stream error rather than a synchronous throw because
    /// the function returns a (non-throwing) stream value.
    public func invokeStreaming(name: ToolName, arguments: String) -> AsyncThrowingStream<ToolEvent, Error> {
        let tool = tools[name]
        return AsyncThrowingStream { continuation in
            guard let tool else {
                continuation.finish(throwing: ToolError.unknown(name))
                return
            }
            if let streaming = tool as? any StreamingBuiltinTool {
                let inner = streaming.invokeStreaming(arguments: arguments)
                let task = Task {
                    do {
                        for try await event in inner {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            // Plain BuiltinTool — adapt to a single-event stream.
            let task = Task {
                do {
                    let result = try await tool.invoke(arguments: arguments)
                    continuation.yield(.result(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
