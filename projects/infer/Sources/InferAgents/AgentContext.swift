import Foundation
@_exported import PluginAPI

public struct RunnerHandle: Sendable, Equatable {
    public let backend: BackendPreference
    public let templateFamily: TemplateFamily?
    public let maxContext: Int
    public let currentTokenCount: Int

    public init(
        backend: BackendPreference,
        templateFamily: TemplateFamily?,
        maxContext: Int,
        currentTokenCount: Int
    ) {
        self.backend = backend
        self.templateFamily = templateFamily
        self.maxContext = maxContext
        self.currentTokenCount = currentTokenCount
    }
}

public struct TranscriptMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

// `ToolSpec`, `ToolCall`, `ToolResult`, `ToolName`, `ToolError`,
// `BuiltinTool`, `StreamingBuiltinTool`, `ToolEvent` moved to the
// `PluginAPI` package so plugins can author tools without depending on
// `InferAgents`. Re-exported via `@_exported import PluginAPI` above.

/// One chunk of retrieval context returned by the host's vector store
/// when an agent calls back through `AgentContext.retrieve` (or via the
/// `vault.search` builtin tool, which wraps the same closure). Kept
/// minimal on purpose: the agent layer doesn't need to know about
/// embeddings, distances, fused-rank scores, or workspace ids — only
/// the chunk's source, text, and a normalised relevance score.
public struct RetrievedChunk: Codable, Equatable, Sendable {
    /// Source identifier (file URL, URL, or arbitrary host-supplied
    /// id). Surfaced to the model so it can cite or follow up.
    public var sourceURI: String
    /// Chunk body. Trimming / summarisation is the host's job — the
    /// agent gets whatever the host's retriever returns.
    public var content: String
    /// Higher = more relevant. Hosts using cosine distance can map
    /// `1 - distance / 2`; hosts using fused rank can pass the RRF
    /// score directly. The agent layer never compares scores across
    /// retrievers, so the absolute scale is up to the host.
    public var score: Double

    public init(sourceURI: String, content: String, score: Double) {
        self.sourceURI = sourceURI
        self.content = content
        self.score = score
    }
}

/// Host-supplied retrieval closure. Performs a single query against
/// whatever index the host wires up (vault vector store, MCP-backed
/// retriever, etc.) and returns up to `topK` chunks ordered by
/// descending relevance. Implementations should be safe to call
/// concurrently; the agent layer makes no isolation assumptions.
///
/// Errors propagate to the caller. An empty array means "nothing
/// relevant in scope" — not an error.
public typealias Retriever = @Sendable (_ query: String, _ topK: Int) async throws -> [RetrievedChunk]

/// Host-supplied tool invocation closure. Wraps the host's
/// `ToolRegistry` so loops driving an agent (`BasicLoop`, the chat
/// view-model's `Generation`, a custom CLI host) can hand the agent
// `ToolInvoker` moved to the `PluginAPI` package alongside the rest
// of the tool primitives (`BuiltinTool`, `ToolName`, etc.) so plugins
// can dispatch other tools by name from inside `register`. Re-exported
// from this module via `@_exported import PluginAPI`.

/// Host-supplied LLM decode closure. Drives one decode round against
/// whatever runner the host has wired up (the active `LlamaRunner` /
/// `MLXRunner` actor under the chat VM, or the `AgentRunner` passed
/// to `BasicLoop`) and returns the fully-accumulated assistant text.
///
/// Required by `customLoop` agents that need to talk to an LLM in
/// addition to (or instead of) calling tools — most importantly the
/// `PlannerAgent`, which decodes the plan as a structured response,
/// then re-decodes per step and again to synthesise a final answer.
/// Deterministic / tool-only agents (`DeterministicPipelineAgent`)
/// don't touch this hook and tolerate it being nil.
///
/// The closure is `@Sendable` because the loop driver hands it across
/// the actor boundary into the agent's `customLoop` context. The
/// returned string is the post-decode assistant body (no streaming,
/// no chunk-by-chunk delivery — the planner needs whole structured
/// output, and adding streaming here would force every customLoop
/// caller to consume an `AsyncThrowingStream` it doesn't want).
public typealias AgentDecoder = @Sendable (_ messages: [TranscriptMessage], _ params: DecodingParams) async throws -> String

/// The set of tools the plugin layer has made available for a given turn,
/// already filtered by per-plugin consent. Agents further restrict this set
/// via `toolsAllow`/`toolsDeny` in their requirements (default hook in
/// `Agent.toolsAvailable`).
public struct ToolCatalog: Sendable, Equatable {
    public let tools: [ToolSpec]

    public init(tools: [ToolSpec] = []) {
        self.tools = tools
    }

    public static let empty = ToolCatalog()
}

/// Read-only handle passed to every `Agent` hook.
///
/// Contains the minimal information an agent needs to shape a turn: a
/// description of the active runner (not the runner actor itself), the
/// filtered tool catalog, a snapshot of the transcript so far, and the
/// current step counter.
///
/// Explicitly **not** in `AgentContext`: the runner actor reference, the
/// `ChatViewModel`, `InferSettings` (agents override via `decodingParams`,
/// not by reading user prefs), the `PluginHost`, or any mutable UI state.
/// The absence list is load-bearing — once a conformance depends on
/// something here, the shape is frozen, so this surface stays thin.
public struct AgentContext: Sendable {
    public let runner: RunnerHandle
    public let tools: ToolCatalog
    public let transcript: [TranscriptMessage]
    public let stepCount: Int
    /// Optional retrieval hook. Nil when the host hasn't wired one
    /// (unit tests, headless contexts) — agents that depend on
    /// retrieval should treat nil as "no corpus available" and
    /// degrade gracefully (e.g. answer from parametric knowledge).
    /// Most agents will reach the corpus via the `vault.search`
    /// builtin tool instead, which wraps the same closure; this hook
    /// is the lower-level surface for compiled `Agent` conformances
    /// that want to enrich context before issuing a tool call.
    public let retrieve: Retriever?
    /// Optional tool invocation hook. Set by the loop driver
    /// (`BasicLoop`, the chat view-model's tool loop, a CLI host)
    /// before calling into agent hooks. `Agent.customLoop`
    /// implementations require this to do useful work — a
    /// deterministic / non-LLM agent that calls tools but doesn't
    /// decode tokens treats nil as a hard error rather than a
    /// degradation, since there's nothing to fall back to.
    public let invokeTool: ToolInvoker?
    /// Optional streaming tool invocation hook. When set, the loop
    /// driver prefers this path for tools that conform to
    /// `StreamingBuiltinTool`, surfacing intermediate `.log` events as
    /// `AgentEvent.toolProgress` in real time. Loop drivers fall back
    /// to `invokeTool` when this is nil. The two hooks are separate so
    /// hosts that don't care about progress (CLI, tests, batch
    /// evaluation) keep their existing one-shot wiring; hosts that do
    /// care (chat UI, future progress disclosure) wire both.
    /// Optional LLM decode hook. Set by the loop driver before
    /// calling into agent hooks. `customLoop` agents that need to
    /// talk to an LLM (e.g. `PlannerAgent`, which generates a plan,
    /// executes per-step, replans on failure, and synthesises a final
    /// answer all via decode rounds) require this. Deterministic /
    /// tool-only agents leave it nil. The default LLM-driven loop
    /// (`BasicLoop` standard path, the chat-VM tool loop) does not
    /// consult this hook — it streams via `AgentRunner.decode`
    /// directly. The hook exists for the inverse case: an agent that
    /// owns its own loop but still wants to decode against the host's
    /// runner.
    public let decode: AgentDecoder?
    public let invokeToolStreaming: StreamingToolInvoker?

    public init(
        runner: RunnerHandle,
        tools: ToolCatalog = .empty,
        transcript: [TranscriptMessage] = [],
        stepCount: Int = 0,
        retrieve: Retriever? = nil,
        invokeTool: ToolInvoker? = nil,
        decode: AgentDecoder? = nil,
        invokeToolStreaming: StreamingToolInvoker? = nil
    ) {
        self.runner = runner
        self.tools = tools
        self.transcript = transcript
        self.stepCount = stepCount
        self.retrieve = retrieve
        self.invokeTool = invokeTool
        self.decode = decode
        self.invokeToolStreaming = invokeToolStreaming
    }
}

public struct AgentTurn: Sendable, Equatable {
    public let userText: String

    public init(userText: String) {
        self.userText = userText
    }
}
