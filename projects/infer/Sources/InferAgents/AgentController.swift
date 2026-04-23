import Foundation
import InferCore

/// Summary row for the agent picker. Captured as a plain `Sendable`
/// struct so views can iterate / filter synchronously without touching
/// the `AgentRegistry` actor on the render path.
public struct AgentListing: Identifiable, Equatable, Sendable {
    public let id: AgentID
    public let name: String
    public let description: String
    public let source: AgentSource
    public let backend: BackendPreference
    public let templateFamily: TemplateFamily?

    /// True when the listing is the synthetic Default row (no registry
    /// entry, derived live from `InferSettings`).
    public let isDefault: Bool

    public init(
        id: AgentID,
        name: String,
        description: String,
        source: AgentSource,
        backend: BackendPreference,
        templateFamily: TemplateFamily?,
        isDefault: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.source = source
        self.backend = backend
        self.templateFamily = templateFamily
        self.isDefault = isDefault
    }
}

/// Side effect the view-model adapter must apply after calling a
/// controller mutation. Returning effects from pure methods keeps the
/// controller unit-testable: tests assert on the list without running a
/// real `LlamaRunner` / `MLXRunner` / vault.
///
/// The adapter is responsible for turning each case into the concrete
/// operation: `pushSystemPrompt` → both runner actors; `resetTranscript`
/// → clear `messages` and null the vault conversation id; and so on.
public enum AgentEffect: Equatable, Sendable {
    /// Insert a UI-only divider row into the transcript naming the new
    /// agent. Emitted by `switchAgent`.
    case insertDivider(agentName: String)

    /// Null the current vault conversation id so the next send starts a
    /// new vault row. Messages stay. Emitted by `switchAgent`.
    case invalidateConversation

    /// Clear the visible transcript AND null the vault conversation id.
    /// Emitted by `applySettings` when the Default agent is active and
    /// the system prompt changed (matching pre-agent behaviour).
    case resetTranscript

    /// Push a system prompt to both runners. Nil means "clear."
    case pushSystemPrompt(String?)

    /// Push sampling parameters to both runners.
    case pushSampling(temperature: Double, topP: Double, seed: UInt64?)
}

/// Main-actor-isolated state machine for agent selection.
///
/// Owns the registry, the current `activeAgentId`, the sorted
/// `availableAgents` snapshot, and the `activeDecodingParams` cache.
/// Mutations return `[AgentEffect]`; the view-model adapter translates
/// those effects into runner calls and transcript mutations.
///
/// No UI, no runner, no `@Observable` — this type is unit-testable
/// under `swift test` without linking `llama.xcframework` or MLX.
@MainActor
public final class AgentController {
    public private(set) var activeAgentId: AgentID = DefaultAgent.id
    public private(set) var availableAgents: [AgentListing] = []
    public private(set) var activeDecodingParams: DecodingParams = DecodingParams(from: .defaults)

    /// Tools the host has exposed to agents. Set at `bootstrap` and
    /// read during `switchAgent` to compose a tool-aware system prompt.
    /// Stays empty when no runtime `ToolRegistry` has been wired in —
    /// PR 1 callers keep defaulting to `.empty`.
    public private(set) var toolCatalog: ToolCatalog = .empty

    /// Id of the agents-layer tool list the active agent exposes for
    /// the current turn. Empty when no tools are allowed (e.g. Default)
    /// or when the catalog is empty. Published so the VM send path can
    /// read `maxSteps > 0` decisions synchronously.
    public private(set) var activeToolSpecs: [ToolSpec] = []

    public let registry: AgentRegistry

    public init(registry: AgentRegistry = AgentRegistry()) {
        self.registry = registry
    }

    /// Initialise from live settings and optionally load user personas
    /// from `personasDirectory`. `firstPartyPersonas` is a list of
    /// bundled JSON URLs (typically resolved from `Bundle.module`) to
    /// register under `.firstParty`. Safe to call more than once.
    public func bootstrap(
        settings: InferSettings,
        firstPartyPersonas: [URL] = [],
        personasDirectory: URL?,
        toolCatalog: ToolCatalog = .empty
    ) async {
        self.activeDecodingParams = DecodingParams(from: settings)
        self.toolCatalog = toolCatalog
        _ = await loadFirstPartyPersonas(from: firstPartyPersonas)
        if let dir = personasDirectory {
            _ = await registry.loadUserPersonas(from: dir)
        }
        await refreshListings()
    }

    /// Register bundled first-party personas by URL. A broken JSON does
    /// not abort the batch: per-file errors are returned so the caller
    /// can surface them without losing the rest of the bundle. User
    /// persona discovery remains driven by directory enumeration in
    /// `AgentRegistry.loadUserPersonas`.
    @discardableResult
    public func loadFirstPartyPersonas(
        from urls: [URL]
    ) async -> [AgentRegistry.PersonaLoadError] {
        var errors: [AgentRegistry.PersonaLoadError] = []
        let decoder = JSONDecoder()
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let agent = try decoder.decode(PromptAgent.self, from: data)
                await registry.register(agent, source: .firstParty)
            } catch {
                errors.append(AgentRegistry.PersonaLoadError(
                    url: url,
                    message: String(describing: error)
                ))
            }
        }
        return errors
    }

    /// Rebuild `availableAgents` from the registry plus the synthetic
    /// Default row. Default always sorts first; the rest are ordered by
    /// source precedence (user > plugin > firstParty) then name.
    public func refreshListings() async {
        let entries = await registry.allEntries()
        let registered: [AgentListing] = entries.map { entry in
            AgentListing(
                id: entry.agent.id,
                name: entry.agent.metadata.name,
                description: entry.agent.metadata.description,
                source: entry.source,
                backend: entry.agent.requirements.backend,
                templateFamily: entry.agent.requirements.templateFamily,
                isDefault: false
            )
        }
        .sorted { lhs, rhs in
            if lhs.source.precedence != rhs.source.precedence {
                return lhs.source.precedence > rhs.source.precedence
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let defaultListing = AgentListing(
            id: DefaultAgent.id,
            name: "Default",
            description: "Infer's built-in assistant with user-configured settings.",
            source: .firstParty,
            backend: .any,
            templateFamily: nil,
            isDefault: true
        )
        self.availableAgents = [defaultListing] + registered
    }

    public func isCompatible(
        _ listing: AgentListing,
        backend: BackendPreference
    ) -> Bool {
        switch listing.backend {
        case .any: return true
        case .llama: return backend == .llama
        case .mlx: return backend == .mlx
        }
    }

    public func incompatibilityReason(_ listing: AgentListing) -> String {
        switch listing.backend {
        case .any: return ""
        case .llama: return "Requires llama.cpp backend"
        case .mlx: return "Requires MLX backend"
        }
    }

    public func activeAgentName() -> String {
        if activeAgentId == DefaultAgent.id { return "Default" }
        return availableAgents.first { $0.id == activeAgentId }?.name ?? activeAgentId
    }

    /// Switch the active agent. Returns the effects the adapter should
    /// apply, in order. No-op (empty list) when the target is already
    /// active or is incompatible with `currentBackend`.
    public func switchAgent(
        to listing: AgentListing,
        currentBackend: BackendPreference,
        settings: InferSettings
    ) async -> [AgentEffect] {
        guard listing.id != activeAgentId else { return [] }
        guard isCompatible(listing, backend: currentBackend) else { return [] }

        activeAgentId = listing.id

        let agent: any Agent
        if listing.id == DefaultAgent.id {
            agent = DefaultAgent(settings: settings)
        } else if let resolved = await registry.agent(id: listing.id) {
            agent = resolved
        } else {
            // Registry evicted the agent (e.g. user deleted persona
            // out-of-band between listing refresh and switch). Fall back
            // to Default rather than ending up in a nil-agent state.
            activeAgentId = DefaultAgent.id
            agent = DefaultAgent(settings: settings)
        }

        let ctx = AgentContext(
            runner: RunnerHandle(
                backend: currentBackend,
                templateFamily: nil,
                maxContext: 0,
                currentTokenCount: 0
            ),
            tools: toolCatalog
        )
        let basePrompt = (try? await agent.systemPrompt(for: ctx)) ?? ""
        let tools = (try? await agent.toolsAvailable(for: ctx)) ?? []
        self.activeToolSpecs = tools
        let composedPrompt = Self.composeSystemPrompt(base: basePrompt, tools: tools)
        let params = agent.decodingParams(for: ctx)
        self.activeDecodingParams = params

        return [
            .insertDivider(agentName: listing.name),
            .invalidateConversation,
            .pushSystemPrompt(composedPrompt.isEmpty ? nil : composedPrompt),
            .pushSampling(
                temperature: params.temperature,
                topP: params.topP,
                seed: settings.seed
            ),
        ]
    }

    /// Combine an agent's base system prompt with a Llama 3.1 tool-call
    /// instruction block. When `tools` is empty, returns `base`
    /// unchanged so agents without tools see no behaviour drift.
    ///
    /// Format is pragmatic rather than spec-authoritative: the section
    /// tells the model which tools exist, which arguments they take,
    /// and exactly which tag sequence to emit (`<|python_tag|>` +
    /// `<|eom_id|>`) so `ToolCallParser.llama3` matches it. Models that
    /// don't understand Llama 3.1 tool syntax will ignore the block.
    public static func composeSystemPrompt(
        base: String,
        tools: [ToolSpec]
    ) -> String {
        guard !tools.isEmpty else { return base }

        var section = ""
        section += "\n\n# Tools\n\n"
        section += "You have access to the following tools. When you need one, emit EXACTLY one tool call in this format and stop — do not add any text after `<|eom_id|>`:\n\n"
        section += "<|python_tag|>{\"name\": \"<tool name>\", \"parameters\": {<json args>}}<|eom_id|>\n\n"
        section += "The tool's result will be returned to you as an `ipython` role message. Then you continue with your final answer.\n\n"
        section += "Available tools:\n"
        for tool in tools {
            section += "- `\(tool.name)`: \(tool.description)\n"
        }
        section += "\nCall at most one tool per turn. If no tool is needed, answer directly without emitting a tool call."

        if base.isEmpty { return section.trimmingCharacters(in: .whitespacesAndNewlines) }
        return base + section
    }

    /// Apply a settings change. Always updates the cached decoding
    /// params when Default is active. Returns runner-push effects only
    /// when Default is active, since non-Default agents are
    /// authoritative over their own system prompt and sampling.
    public func applySettings(
        _ new: InferSettings,
        previous: InferSettings
    ) -> [AgentEffect] {
        guard activeAgentId == DefaultAgent.id else { return [] }

        self.activeDecodingParams = DecodingParams(from: new)

        var effects: [AgentEffect] = []
        let promptChanged = previous.systemPrompt != new.systemPrompt
        if promptChanged {
            effects.append(.pushSystemPrompt(
                new.systemPrompt.isEmpty ? nil : new.systemPrompt
            ))
        }
        effects.append(.pushSampling(
            temperature: new.temperature,
            topP: new.topP,
            seed: new.seed
        ))
        if promptChanged {
            effects.append(.resetTranscript)
        }
        return effects
    }
}
