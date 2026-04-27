import Foundation

/// One observable signal from a streaming tool invocation.
///
/// Streaming tools emit zero or more `.log` events (and, optionally,
/// `.progress` for tools that have a numeric notion of completion)
/// followed by exactly one terminal `.result`. Consumers — `BasicLoop`,
/// the chat view-model's tool loop, tests — drain the stream and treat
/// the final `.result` as the canonical `ToolResult` they would have
/// gotten from the simple `BuiltinTool.invoke` path.
///
/// The event shape mirrors `AgentEvent` deliberately: a tool's `.log`
/// becomes the loop's `.toolProgress`, and the tool's `.result` becomes
/// the loop's `.toolResulted`. That symmetry is what lets the loop
/// drive a streaming tool without learning anything tool-specific.
public enum ToolEvent: Sendable, Equatable {
    /// Free-form progress line. Surface verbatim in the disclosure UI.
    case log(String)
    /// 0.0 ... 1.0 fraction. Optional — most tools won't emit this.
    case progress(Double)
    /// Terminal result. Always the last event; subsequent events are
    /// ignored by the loop driver.
    case result(ToolResult)
}

/// Opt-in extension of `BuiltinTool` for tools that can emit progress
/// during a long-running invocation. The simple `invoke(arguments:)`
/// path remains the contract — any `BuiltinTool` is callable from any
/// agent loop. This protocol just adds a streaming alternative for
/// tools that benefit (Quarto rendering, large file reads, multi-step
/// retrieval) and for callers (UI loops) that want progress.
///
/// Adopters MUST emit exactly one `.result` event. They SHOULD finish
/// the stream after that event. Throwing from inside the stream is
/// reserved for infrastructure failures the loop should treat as
/// fatal — tool-side errors that the model can recover from go in the
/// terminal `ToolResult(error:)`, exactly like the simple path.
public protocol StreamingBuiltinTool: BuiltinTool {
    func invokeStreaming(arguments: String) -> AsyncThrowingStream<ToolEvent, Error>
}

extension StreamingBuiltinTool {
    /// Default `invoke` for tools that prefer to author the streaming
    /// path. Drains the stream, returning the terminal `.result`.
    /// Adopters can still override `invoke` directly if they have a
    /// faster non-streaming path (e.g. cached results).
    public func invoke(arguments: String) async throws -> ToolResult {
        let stream = invokeStreaming(arguments: arguments)
        for try await event in stream {
            if case .result(let r) = event { return r }
        }
        return ToolResult(output: "", error: "streaming tool ended without a result event")
    }
}

/// Host-supplied streaming invocation closure, parallel to
/// `ToolInvoker`. Wraps the registry's `invokeStreaming(name:arguments:)`
/// so a loop driver doesn't need a registry reference. Loop drivers
/// fall back to `ToolInvoker` when this hook isn't wired.
public typealias StreamingToolInvoker = @Sendable (_ name: ToolName, _ arguments: String) -> AsyncThrowingStream<ToolEvent, Error>
