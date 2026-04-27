import Foundation

/// Drains a streaming tool invocation, surfacing per-line progress to
/// the host while collecting the terminal `ToolResult`.
///
/// Extracted from `ChatViewModel.maybeRunToolLoop` so the chat-VM glue
/// is one line and the streaming-consumption shape is testable without
/// llama/MLX/SwiftUI dependencies. Both the chat VM and `BasicLoop`
/// can route through this helper; today only the chat VM does, but
/// keeping the surface in `InferAgents` means a CLI / batch host gets
/// the same progress wiring for free.
///
/// Contract:
/// - Exactly one `ToolResult` returned. A stream that ends without a
///   `.result` event yields `ToolResult(error: "stream ended without a result")`
///   so the caller's downstream "feed back to the model" logic always
///   has something to feed. This mirrors `BasicLoop`.
/// - `.log` events become `onProgress(line)` calls AND an
///   `AgentEvent.toolProgress` sent to `onEvent` (when set). The two
///   hooks are separate so a host can update transient UI state
///   (latest-line label) on `onProgress` while persisting the same
///   line through the trace/event-stream pipeline on `onEvent`.
/// - `.progress` events are currently passed through silently. A
///   future overload could add a numeric callback; for now no tool
///   emits these.
/// - Stream errors are caught and converted into `ToolResult(error:)`
///   so the model sees the failure and can recover; this matches the
///   chat VM's existing one-shot path. Cancellation propagates
///   (`CancellationError` is rethrown by the awaiting `for-try-await`,
///   which the caller's outer task treats as a cancelled turn).
public enum ToolStreamConsumer {
    public static func consume(
        registry: ToolRegistry,
        name: ToolName,
        arguments: String,
        onProgress: @Sendable (String) async -> Void = { _ in },
        onEvent: @Sendable (AgentEvent) async -> Void = { _ in }
    ) async -> ToolResult {
        var collected: ToolResult?
        do {
            for try await event in await registry.invokeStreaming(name: name, arguments: arguments) {
                switch event {
                case .log(let line):
                    await onProgress(line)
                    await onEvent(.toolProgress(name: name, message: line))
                case .progress:
                    break
                case .result(let r):
                    collected = r
                }
            }
        } catch {
            return ToolResult(
                output: "",
                error: "tool invocation failed: \(error)"
            )
        }
        return collected ?? ToolResult(
            output: "",
            error: "tool stream ended without a result"
        )
    }
}
