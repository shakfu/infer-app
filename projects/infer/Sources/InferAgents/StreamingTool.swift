import Foundation
import PluginAPI

// `ToolEvent` and `StreamingBuiltinTool` moved to the `PluginAPI`
// package — see `Sources/PluginAPI/Tool.swift`. The
// `StreamingToolInvoker` typealias below stays in `InferAgents`
// because it is host-wiring sugar (it captures the host's
// `ToolRegistry`), not a protocol plugins author against.

/// Host-supplied streaming invocation closure, parallel to
/// `ToolInvoker`. Wraps the registry's `invokeStreaming(name:arguments:)`
/// so a loop driver doesn't need a registry reference. Loop drivers
/// fall back to `ToolInvoker` when this hook isn't wired.
public typealias StreamingToolInvoker = @Sendable (_ name: ToolName, _ arguments: String) -> AsyncThrowingStream<ToolEvent, Error>
