import Foundation

/// Stable, dot-namespaced identifier for a tool — e.g. `wiki.search`,
/// `builtin.clock.now`, `mcp.<server>.<tool>`. Used as the `ToolRegistry`
/// key on the host side and shown to the model in the tool list.
public typealias ToolName = String

/// What the model sees about a tool: its name and a free-form
/// description. The description should include enough guidance for the
/// model to know when to call the tool and what JSON to pass.
public struct ToolSpec: Codable, Equatable, Sendable {
    public var name: ToolName
    public var description: String

    public init(name: ToolName, description: String = "") {
        self.name = name
        self.description = description
    }
}

/// One model-emitted tool invocation. `arguments` is kept as raw JSON
/// (a `String`) rather than a decoded type so the transcript survives
/// schema evolution without the agent layer needing per-tool types.
public struct ToolCall: Codable, Equatable, Sendable {
    public var name: ToolName
    public var arguments: String

    public init(name: ToolName, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

/// Outcome of a tool invocation. `error` is non-nil for tool-side
/// failures the model should see and recover from; throwing from
/// `BuiltinTool.invoke` is reserved for programmer-error / loop-fatal
/// failures.
public struct ToolResult: Codable, Equatable, Sendable {
    public var output: String
    public var error: String?

    public init(output: String, error: String? = nil) {
        self.output = output
        self.error = error
    }
}

public enum ToolError: Error, Equatable, Sendable {
    /// The loop tried to invoke a tool the registry doesn't know.
    /// Loop-level invariant violation, not a tool-side error.
    case unknown(ToolName)
}

/// A native Swift tool. Conformances live in plugins
/// (`projects/plugins/plugin_<name>/`) or in the host's first-party
/// tool catalog.
public protocol BuiltinTool: Sendable {
    var name: ToolName { get }
    var spec: ToolSpec { get }

    /// Run the tool. `arguments` is a raw JSON string — the tool
    /// decodes what it expects. Return `ToolResult(output:)` on
    /// success or `ToolResult(output: "", error:)` on a caught
    /// failure. Throwing is reserved for programmer-error /
    /// loop-fatal failures, not for tool-side errors the model
    /// should be allowed to see.
    func invoke(arguments: String) async throws -> ToolResult
}

/// One observable signal from a streaming tool invocation. Streaming
/// tools emit zero or more `.log` events (and optionally `.progress`)
/// followed by exactly one terminal `.result`.
public enum ToolEvent: Sendable, Equatable {
    case log(String)
    case progress(Double)
    case result(ToolResult)
}

/// Opt-in extension of `BuiltinTool` for tools that emit progress
/// during a long-running invocation. The simple `invoke(arguments:)`
/// path stays the canonical contract; this protocol just adds a
/// streaming alternative for tools (Quarto rendering, large reads,
/// multi-step retrieval) and callers (UI loops) that benefit.
///
/// Adopters MUST emit exactly one `.result` event and SHOULD finish
/// the stream after that event. Throwing from inside the stream is
/// for infrastructure failures the loop should treat as fatal —
/// tool-side errors that the model can recover from go in the
/// terminal `ToolResult(error:)`.
public protocol StreamingBuiltinTool: BuiltinTool {
    func invokeStreaming(arguments: String) -> AsyncThrowingStream<ToolEvent, Error>
}

extension StreamingBuiltinTool {
    /// Default `invoke` for tools that prefer to author the streaming
    /// path. Drains the stream, returning the terminal `.result`.
    public func invoke(arguments: String) async throws -> ToolResult {
        let stream = invokeStreaming(arguments: arguments)
        for try await event in stream {
            if case .result(let r) = event { return r }
        }
        return ToolResult(output: "", error: "streaming tool ended without a result event")
    }
}

/// Host-supplied tool invocation closure. Wraps the host's
/// `ToolRegistry` so callers — agent loops, and plugins that want to
/// dispatch tools belonging to *other* plugins — can execute tools
/// by name without holding the registry actor.
///
/// `name` corresponds to a `ToolSpec.name` from the merged catalog
/// (built-ins + every plugin's contributions + MCP tools); `arguments`
/// is a JSON-encoded string matching the tool's schema. Implementations
/// throw on unknown tools or argument-parse failures the loop should
/// treat as fatal; tool-side errors the model should see and recover
/// from arrive as `ToolResult(error:)` with no throw. Mirrors
/// `BuiltinTool.invoke`'s contract.
///
/// **Cross-plugin call timing.** The closure dispatches against the
/// registry as it stands *at call time*, not at register time. So
/// plugin B can be handed an invoker during `register` even though
/// plugin A's tools haven't been registered yet — by the time B's
/// tool actually runs (during a chat turn), A's tools are present.
public typealias ToolInvoker = @Sendable (_ name: ToolName, _ arguments: String) async throws -> ToolResult
