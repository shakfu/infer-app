import Foundation

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

public struct ToolSpec: Codable, Equatable, Sendable {
    public var name: ToolName
    public var description: String

    public init(name: ToolName, description: String = "") {
        self.name = name
        self.description = description
    }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public var name: ToolName
    /// Arguments as a raw JSON string. Kept as text rather than a decoded
    /// type so the transcript can survive schema evolution without the
    /// agent layer needing to know each tool's schema.
    public var arguments: String

    public init(name: ToolName, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Codable, Equatable, Sendable {
    public var output: String
    public var error: String?

    public init(output: String, error: String? = nil) {
        self.output = output
        self.error = error
    }
}

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

    public init(
        runner: RunnerHandle,
        tools: ToolCatalog = .empty,
        transcript: [TranscriptMessage] = [],
        stepCount: Int = 0,
        retrieve: Retriever? = nil
    ) {
        self.runner = runner
        self.tools = tools
        self.transcript = transcript
        self.stepCount = stepCount
        self.retrieve = retrieve
    }
}

public struct AgentTurn: Sendable, Equatable {
    public let userText: String

    public init(userText: String) {
        self.userText = userText
    }
}
