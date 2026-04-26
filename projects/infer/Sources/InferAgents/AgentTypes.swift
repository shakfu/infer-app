import Foundation
import InferCore

/// Stable, URL-safe identifier for an agent. Used as the registry key,
/// for transcript attribution, and for consent scoping.
///
/// A struct over `String` rather than a `typealias` so the type system
/// keeps `AgentID` and free-form `String` distinct. The wire format is a
/// bare JSON string (custom `Codable` below), so existing on-disk persona
/// files and persisted traces round-trip unchanged. `ExpressibleByStringLiteral`
/// keeps the in-source ergonomics of the old typealias for tests and
/// constants (`let id: AgentID = "writing.editor"`).
public struct AgentID: RawRepresentable, Hashable, Sendable, Codable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.rawValue = try c.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static func < (lhs: AgentID, rhs: AgentID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { rawValue }

    public var isEmpty: Bool { rawValue.isEmpty }
}

/// Tool name as exposed by the tool registry. A plain string today; could
/// become a newtype later without source-breaking call sites that construct
/// it from literals.
public typealias ToolName = String

public struct AgentMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var icon: String?
    public var author: String?

    public init(
        name: String,
        description: String = "",
        icon: String? = nil,
        author: String? = nil
    ) {
        self.name = name
        self.description = description
        self.icon = icon
        self.author = author
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, icon, author
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.author = try c.decodeIfPresent(String.self, forKey: .author)
    }
}

/// User-facing classification for an agent. See `docs/dev/agent_kinds.md`.
///
/// `persona` = role + context, no tool execution. Safe-by-construction:
/// even if a persona's JSON declares `toolsAllow`, the runtime guarantees
/// no tools are exposed to it (`PromptAgent.toolsAvailable` returns `[]`).
///
/// `agent` = persona + tool use and/or composition. Can run code on the
/// user's behalf via the tool registry.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case persona
    case agent
}

public enum TemplateFamily: String, Codable, Sendable, CaseIterable {
    case llama3
    case qwen
    case hermes
    case openai

    /// Best-effort classification of a loaded GGUF's Jinja chat template
    /// into one of the known families. Returns nil for unknown templates
    /// and for nil/empty input.
    ///
    /// Heuristics, in priority order:
    /// 1. `<|python_tag|>` — unambiguously Llama 3.1 tool-calling.
    /// 2. Llama 3.x header tokens (`<|start_header_id|>` + `<|eot_id|>`)
    ///    without the python tag — Llama 3 base/instruct chat shape.
    /// 3. ChatML (`<|im_start|>` / `<|im_end|>`) with `<tool_call>`
    ///    references — Qwen-2.5/3 (Hermes-3 also uses this shape but
    ///    is rarer in GGUF metadata; we err toward Qwen).
    /// 4. ChatML alone, no `<tool_call>` — return nil. The model may
    ///    chat fine but its tool-calling syntax is unspecified, so a
    ///    tool-using agent should fail loud rather than silently emit
    ///    Llama 3.1 tags into a Qwen template.
    ///
    /// Conservative on purpose: a wrong positive here means the picker
    /// allows an incompatible agent and the user gets garbled output.
    /// A nil return surfaces in the UI as "template family unknown,"
    /// which is recoverable — the user can override or pick a tool-
    /// less persona instead.
    public static func fingerprint(template: String?) -> TemplateFamily? {
        guard let template, !template.isEmpty else { return nil }
        if template.contains("<|python_tag|>") {
            return .llama3
        }
        if template.contains("<|start_header_id|>")
            && template.contains("<|eot_id|>") {
            return .llama3
        }
        let isChatML = template.contains("<|im_start|>")
        let hasToolCall = template.contains("<tool_call>")
            || template.contains("tool_call")
        if isChatML && hasToolCall {
            return .qwen
        }
        return nil
    }
}

public enum BackendPreference: String, Codable, Sendable, CaseIterable {
    case llama
    case mlx
    case any
}

public struct AgentRequirements: Codable, Equatable, Sendable {
    public var backend: BackendPreference
    public var templateFamily: TemplateFamily?
    public var minContext: Int?
    public var toolsAllow: [ToolName]
    public var toolsDeny: [ToolName]
    public var autoApprove: [ToolName]

    public init(
        backend: BackendPreference = .any,
        templateFamily: TemplateFamily? = nil,
        minContext: Int? = nil,
        toolsAllow: [ToolName] = [],
        toolsDeny: [ToolName] = [],
        autoApprove: [ToolName] = []
    ) {
        self.backend = backend
        self.templateFamily = templateFamily
        self.minContext = minContext
        self.toolsAllow = toolsAllow
        self.toolsDeny = toolsDeny
        self.autoApprove = autoApprove
    }

    private enum CodingKeys: String, CodingKey {
        case backend, templateFamily, minContext, toolsAllow, toolsDeny, autoApprove
    }

    /// Tolerant decoding: every field is optional in JSON, so partial
    /// `requirements` blocks (e.g. `{"toolsAllow": ["..."]}` with no
    /// `backend`) decode cleanly with the omitted fields taking their
    /// init defaults. Synthesized `Codable` would reject this because
    /// `backend` is non-optional in Swift; the bug is that the previous
    /// `try? c.decode(AgentRequirements.self, ...)` in `PromptAgent`
    /// silently swallowed the error and produced a fully-defaulted
    /// requirements block, dropping the user's declared tools.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.backend = (try? c.decodeIfPresent(BackendPreference.self, forKey: .backend)) ?? .any
        self.templateFamily = try c.decodeIfPresent(TemplateFamily.self, forKey: .templateFamily)
        self.minContext = try c.decodeIfPresent(Int.self, forKey: .minContext)
        self.toolsAllow = try c.decodeIfPresent([ToolName].self, forKey: .toolsAllow) ?? []
        self.toolsDeny = try c.decodeIfPresent([ToolName].self, forKey: .toolsDeny) ?? []
        self.autoApprove = try c.decodeIfPresent([ToolName].self, forKey: .autoApprove) ?? []
    }
}

public struct DecodingParams: Codable, Equatable, Sendable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int

    public init(temperature: Double, topP: Double, maxTokens: Int) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    public init(from settings: InferSettings) {
        self.temperature = settings.temperature
        self.topP = settings.topP
        self.maxTokens = settings.maxTokens
    }
}

/// Result of a single agent's `run` (or, equivalently, of one segment
/// inside a composition). Composition drivers (`CompositionController`,
/// landing in M5a-runtime) consume this to decide whether to continue
/// down a chain, take a fallback branch, or settle on a final answer.
///
/// The four cases map to `agent_composition.md`:
/// - `.completed`: agent produced a final answer normally. The trace's
///   terminator is `.finalAnswer(text)`. For a `chain`, the next agent
///   sees this text as its user turn (after sentinel-stripping).
/// - `.handoff`: the agent emitted a `<<HANDOFF>>` envelope asking the
///   composition driver to dispatch to a specific peer. Visible text
///   is what the user sees; `payload` is the unstructured-for-v1
///   instruction the next agent receives.
/// - `.abandoned`: the agent decided not to answer (e.g. branch
///   predicate failed). No trace terminator was emitted.
/// - `.failed`: the agent errored out. Composition drivers may try a
///   fallback chain depending on `PromptAgent.fallback`.
public enum AgentOutcome: Sendable, Equatable {
    case completed(text: String, trace: StepTrace)
    case handoff(target: AgentID, payload: String, trace: StepTrace)
    case abandoned(reason: String, trace: StepTrace)
    case failed(message: String, trace: StepTrace)
}

public enum LoopDecision: Sendable, Equatable {
    case `continue`
    case stop(reason: String)
    case stopAndSummarise
}

public enum AgentError: Error, Sendable, Equatable {
    /// JSON parse or validation failure. Message is user-facing (surfaced
    /// in the Agents tab as the reason a persona failed to load).
    case invalidPersona(String)
    /// The persona file declared a `schemaVersion` this build doesn't know
    /// how to read. See `PromptAgent.supportedSchemaVersions`.
    case unsupportedSchemaVersion(Int)
    /// The agent attempted an action that requires a tool invoker
    /// (`AgentContext.invokeTool`) but the host did not wire one. Hits
    /// when a deterministic agent's `customLoop` calls tools in a
    /// context that wasn't constructed by a real loop driver
    /// (typically a misconfigured test or a unit context built from
    /// `AgentController.activate` rather than `BasicLoop`).
    case toolInvokerMissing
    /// A deterministic agent's tool call referenced a tool that isn't
    /// in the catalog or rejected the supplied arguments at the JSON
    /// layer. The error string is propagated from the underlying
    /// invoker (`ToolError.unknown` or a per-tool decoding error).
    case toolDispatchFailed(String)
}

public enum AgentSource: Sendable, Equatable {
    case user
    case plugin
    case firstParty

    /// Higher wins on id collision. See `AgentRegistry.register`.
    public var precedence: Int {
        switch self {
        case .user: return 3
        case .plugin: return 2
        case .firstParty: return 1
        }
    }
}
