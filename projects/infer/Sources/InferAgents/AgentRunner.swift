import Foundation

/// Runner-agnostic decode contract.
///
/// `AgentRunner` is the seam between the agent layer (which knows
/// about hooks, tool calls, traces, and composition) and whatever
/// actually produces tokens (`LlamaRunner`, `MLXRunner`, a remote
/// API client, a deterministic mock for tests, an external
/// process). Conformances are stateless from the loop's point of
/// view: each call receives the full transcript and decodes a
/// single assistant turn.
///
/// Why stateless: the only loop driver in the host today
/// (`ChatViewModel/Generation.swift`) is deeply entangled with KV
/// caches, vault writes, MainActor mutation, and SwiftUI state.
/// `BasicLoop`, which lives in `InferAgents` and consumes this
/// protocol, is the alternative — small, host-agnostic, runs in
/// CLI / batch / headless contexts. Stateless decode lets the same
/// agent run against any token producer without the producer
/// needing to expose its internal conversation state.
///
/// The agent layer also runs deterministic, non-LLM agents (see
/// `Agent.customLoop`). Those bypass `AgentRunner` entirely — the
/// loop driver checks `customLoop` first and only constructs an
/// `AgentRunner` call when the agent has no custom implementation.
public protocol AgentRunner: Sendable {
    /// Decode one assistant turn against `messages`. The conformance
    /// is responsible for applying its template family's chat
    /// formatting (system prompt placement, role tags, tool-result
    /// framing) and for honouring `params` (temperature, topP, max
    /// tokens, optional seed).
    ///
    /// Returns an `AsyncThrowingStream` of token-or-chunk strings.
    /// Consumers concatenate the chunks into the assistant's emitted
    /// text. The stream finishes when the model emits its end-of-turn
    /// marker (`<|eom_id|>`, `</s>`, etc.) or when `maxTokens` is hit;
    /// it throws on cancellation or runtime failure.
    func decode(
        messages: [TranscriptMessage],
        params: DecodingParams
    ) -> AsyncThrowingStream<String, Error>
}
