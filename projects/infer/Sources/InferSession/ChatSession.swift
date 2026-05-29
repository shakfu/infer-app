import Foundation
import InferAppCore
import InferCore

/// Headless, UI-agnostic chat orchestrator for the cloud backend. This is
/// the seam that lets the same chat logic drive both the SwiftUI app and a
/// non-interactive CLI: it owns a `CloudRunner` and exposes a small async
/// surface (`configure` / `send` / `reset`) with no SwiftUI, AppKit, or
/// binary-framework dependencies, so it builds with plain `swift build` and
/// is unit-testable against a stubbed `CloudClient`.
///
/// The send path goes through the `ChatRunner` protocol (`respondToUser`)
/// rather than `CloudRunner`'s own `sendUserMessage`, so this exercises the
/// same abstraction the app's chat view-model is being refactored onto.
/// Cloud-specific configuration (`configure`) still talks to the concrete
/// `CloudRunner` because the protocol intentionally stays narrow — there is
/// no model to load for cloud, only provider/model/key to record.
///
/// Multi-turn state lives in the runner: `CloudRunner` resends the full
/// transcript each turn and appends the new user/assistant pair, so calling
/// `send` repeatedly continues the same conversation. Use `reset` to clear
/// it while keeping the provider configured.
public struct ChatSession: Sendable {
    public let runner: CloudRunner
    /// Backend-agnostic multi-turn engine wrapping the same `runner`. Owns the
    /// transcript and the incremental-vs-rebuild driving logic; `ChatSession`
    /// adds the cloud-specific `configure` the `ChatRunner` protocol does not
    /// cover. Use `engine` directly for `regenerate` / `editAndResend` and to
    /// read the `transcript`.
    public let engine: ChatEngine

    /// - Parameter clientFactory: injection point for the HTTP client.
    ///   Defaults to the real per-provider clients; tests pass a stub that
    ///   yields a canned stream without touching the network.
    public init(
        clientFactory: @escaping @Sendable (CloudProvider, String) -> CloudClient = CloudRunner.defaultClientFactory
    ) {
        let runner = CloudRunner(clientFactory: clientFactory)
        self.runner = runner
        self.engine = ChatEngine(runner: runner)
    }

    /// Record provider/model/credentials and reset the transcript. Throws
    /// `CloudError.missingKey` / `.invalidEndpoint` per `CloudRunner.configure`.
    public func configure(
        provider: CloudProvider,
        model: String,
        apiKey: String,
        systemPrompt: String? = nil,
        params: CloudGenerationParams = CloudGenerationParams()
    ) async throws {
        try await runner.configure(
            provider: provider,
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            params: params
        )
    }

    /// Send one user turn and return the assembled assistant reply. Chunks
    /// are forwarded to `onChunk` as they stream in (used by the CLI to
    /// print incrementally). Cancelling the surrounding task terminates the
    /// stream; call `requestStop` first if you also want the runner-side
    /// work to short-circuit.
    @discardableResult
    public func send(
        _ text: String,
        maxTokens: Int = 512,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try await engine.send(text, maxTokens: maxTokens, onChunk: onChunk)
    }

    /// Stop an in-flight `send`.
    public func requestStop() async {
        await engine.requestStop()
    }

    /// Clear the conversation transcript, preserving the configured
    /// provider/model/system prompt.
    public func reset() async {
        await engine.reset()
    }
}
