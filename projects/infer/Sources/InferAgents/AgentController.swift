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

    /// Persona vs agent classification (`docs/dev/agent_kinds.md`). The
    /// Default row is a persona (no tools). Library/picker UIs group by
    /// this value.
    public let kind: AgentKind

    /// True when the listing is the synthetic Default row (no registry
    /// entry, derived live from `InferSettings`).
    public let isDefault: Bool

    /// Unicode-safe, single-token label for the role column in the
    /// transcript ("code-helper", not "Code Helper"). Computed once from
    /// `name` at listing construction; transcript renderers should
    /// prefer `ChatMessage.agentLabel` (snapshotted at send time) so
    /// deleted/renamed personas still render correctly in history.
    public let displayLabel: String

    public init(
        id: AgentID,
        name: String,
        description: String,
        source: AgentSource,
        backend: BackendPreference,
        templateFamily: TemplateFamily?,
        kind: AgentKind,
        isDefault: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.source = source
        self.backend = backend
        self.templateFamily = templateFamily
        self.kind = kind
        self.isDefault = isDefault
        self.displayLabel = Self.makeDisplayLabel(from: name, fallbackId: id)
    }

    /// Flatten a human-readable name into a transcript role-column label.
    /// Strategy: lowercase, split on anything that isn't a Unicode
    /// alphanumeric, join tokens with `-`. Preserves CJK runs as single
    /// tokens (they're already alphanumeric). Falls back to `fallbackId`
    /// if the name contains no alphanumerics (e.g. emoji-only).
    public static func makeDisplayLabel(
        from name: String,
        fallbackId: AgentID
    ) -> String {
        var tokens: [String] = []
        var current = ""
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard !tokens.isEmpty else { return fallbackId }
        return tokens.joined(separator: "-")
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

    /// Tool-call template family the active agent expects in its
    /// emitted tool calls. Read by the chat view-model's tool loop
    /// when choosing which `ToolCallParser` family to feed first-decode
    /// text into. Defaults to `.llama3` to preserve pre-M4 behaviour
    /// for any agent that doesn't declare a `templateFamily`.
    public private(set) var activeToolFamily: TemplateFamily = .llama3

    /// Per-file parse failures from the most recent `bootstrap`. Reset
    /// each bootstrap so the UI shows only currently-broken files
    /// (not a historical accretion). Published so the Agents tab can
    /// render a dismissible diagnostics banner instead of silently
    /// swallowing malformed JSON.
    public private(set) var libraryDiagnostics: [AgentRegistry.PersonaLoadError] = []

    /// Template family detected from the currently-loaded GGUF, or nil
    /// when no model is loaded / the runner backend has no notion of
    /// templates (MLX). Pushed in by the chat view-model after a model
    /// load completes; consumed by `isCompatible` to fail loud on
    /// agents that declare a `templateFamily` requirement.
    /// `docs/dev/agent_implementation_plan.md` decision 5: detection
    /// lives on the runner side so `InferAgents` stays free of llama
    /// / MLX dependencies.
    public private(set) var detectedTemplateFamily: TemplateFamily? = nil

    public let registry: AgentRegistry

    /// Process-lifetime broadcast of `AgentEvent`s emitted by the active
    /// turn. UX plan Phase 0.2: streaming disclosures, transcript live
    /// updates, and exporters subscribe here rather than polling
    /// `messages[i].steps`. Single-consumer (`AsyncStream`); if a future
    /// caller needs multicast, wrap it then.
    public nonisolated let events: AsyncStream<AgentEvent>
    private nonisolated let eventContinuation: AsyncStream<AgentEvent>.Continuation

    public init(registry: AgentRegistry = AgentRegistry()) {
        self.registry = registry
        var cont: AsyncStream<AgentEvent>.Continuation!
        self.events = AsyncStream<AgentEvent>(bufferingPolicy: .unbounded) { c in
            cont = c
        }
        self.eventContinuation = cont
    }

    /// Yield an event to the broadcast stream. Called by the loop driver
    /// at every state transition (tool requested, running, resulted,
    /// chunk, terminated). The driver remains responsible for applying
    /// the event's effect on `ChatMessage` — the stream is observer-only.
    public nonisolated func emit(_ event: AgentEvent) {
        eventContinuation.yield(event)
    }

    /// Single-directory back-compat shim for the array-based
    /// `bootstrap(personasDirectories:)`. Predates the schema-v2 split
    /// of user content into `personas/` and `agents/` subdirs; kept so
    /// older test call sites remain valid.
    public func bootstrap(
        settings: InferSettings,
        firstPartyPersonas: [URL] = [],
        personasDirectory: URL?,
        toolCatalog: ToolCatalog = .empty
    ) async {
        await bootstrap(
            settings: settings,
            firstPartyPersonas: firstPartyPersonas,
            personasDirectories: personasDirectory.map { [$0] } ?? [],
            toolCatalog: toolCatalog
        )
    }

    /// Initialise from live settings and optionally load user personas
    /// from `personasDirectories`. Each directory is scanned independently
    /// for `*.json`; missing directories are silently skipped (a fresh
    /// install has neither). `firstPartyPersonas` is a list of bundled
    /// JSON URLs (typically resolved from `Bundle.module`) to register
    /// under `.firstParty`. Safe to call more than once.
    public func bootstrap(
        settings: InferSettings,
        firstPartyPersonas: [URL] = [],
        personasDirectories: [URL] = [],
        toolCatalog: ToolCatalog = .empty
    ) async {
        self.activeDecodingParams = DecodingParams(from: settings)
        self.toolCatalog = toolCatalog
        var diagnostics: [AgentRegistry.PersonaLoadError] = []
        diagnostics.append(contentsOf: await loadFirstPartyPersonas(from: firstPartyPersonas))
        for dir in personasDirectories {
            diagnostics.append(contentsOf: await registry.loadUserPersonas(from: dir))
        }
        // Cross-agent reference validation runs after every file is
        // registered — order of file load is undefined, so per-file
        // existence checks would race. Cycles + dangling references
        // surface here as `.warning` diagnostics.
        diagnostics.append(contentsOf: await registry.validateCompositionReferences())
        self.libraryDiagnostics = diagnostics
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
        for url in urls {
            do {
                let agent = try AgentRegistry.decodePersona(at: url)
                await registry.register(agent, source: .firstParty, sourceURL: url)
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
                kind: Self.kind(of: entry.agent),
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
            kind: .persona,
            isDefault: true
        )
        self.availableAgents = [defaultListing] + registered
    }

    /// Classify any `Agent` conformance for the listing UI. JSON-backed
    /// agents carry their authored `kind`; compiled conformances are
    /// derived from whether they expose tools (presence of `toolsAllow`
    /// is treated as agent-shaped here so the picker badges them
    /// correctly).
    private static func kind(of agent: any Agent) -> AgentKind {
        if let prompt = agent as? PromptAgent { return prompt.kind }
        return agent.requirements.toolsAllow.isEmpty ? .persona : .agent
    }

    /// Push the runner-detected template family in. Caller (chat
    /// view-model) calls this after a model load completes and again
    /// with nil after unload. Refreshes `availableAgents` listings so
    /// the picker re-evaluates compatibility on the next render.
    public func setDetectedTemplateFamily(_ family: TemplateFamily?) {
        guard family != detectedTemplateFamily else { return }
        detectedTemplateFamily = family
    }

    public func isCompatible(
        _ listing: AgentListing,
        backend: BackendPreference
    ) -> Bool {
        // Backend match comes first — a Qwen-template Llama agent
        // running on the MLX backend is wrong for two independent
        // reasons; surface the backend one.
        switch listing.backend {
        case .any: break
        case .llama: if backend != .llama { return false }
        case .mlx: if backend != .mlx { return false }
        }
        // Template-family check only applies when the agent declares a
        // requirement. An unset `templateFamily` means "any template
        // works for this agent" (most personas) — those stay
        // compatible. When the requirement is set and we have a
        // detection, the two must match. When the requirement is set
        // but detection is nil (no model loaded yet, or template
        // unrecognised), the picker fails loud — better than silently
        // emitting Llama 3.1 tags into a Qwen template at first send.
        if let required = listing.templateFamily {
            guard let detected = detectedTemplateFamily else { return false }
            return detected == required
        }
        return true
    }

    public func incompatibilityReason(
        _ listing: AgentListing,
        backend: BackendPreference
    ) -> String {
        // Backend mismatch wins — the user can't fix template before
        // fixing backend. Surface the more fundamental reason first.
        switch listing.backend {
        case .any: break
        case .llama: if backend != .llama { return "Requires llama.cpp backend" }
        case .mlx: if backend != .mlx { return "Requires MLX backend" }
        }
        if let required = listing.templateFamily {
            if let detected = detectedTemplateFamily {
                if detected != required {
                    return "Requires \(required.rawValue) template — current: \(detected.rawValue)"
                }
                return ""
            }
            return "Requires \(required.rawValue) template — none detected"
        }
        return ""
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
        let runnerEffects = await activate(
            agentId: listing.id,
            currentBackend: currentBackend,
            settings: settings
        )
        return [
            .insertDivider(agentName: listing.name),
            .invalidateConversation,
        ] + runnerEffects
    }

    /// Mid-composition agent activation. M5a-runtime Phase B: when a
    /// chain hops from agent A to agent B inside a single user turn,
    /// the runner needs B's system prompt + sampling pushed (so the KV
    /// cache rewinds and the next decode is shaped correctly), but the
    /// transcript should NOT get a divider row and the vault
    /// conversation MUST stay open — chain segments belong to one
    /// logical user turn, not separate ones. Returns runner-state
    /// effects only; the caller appends a fresh assistant message for
    /// the new segment with its own agent attribution.
    public func activateForSegment(
        agentId: AgentID,
        currentBackend: BackendPreference,
        settings: InferSettings
    ) async -> [AgentEffect] {
        guard agentId != activeAgentId else { return [] }
        return await activate(
            agentId: agentId,
            currentBackend: currentBackend,
            settings: settings
        )
    }

    /// Shared body for `switchAgent` and `activateForSegment`. Resolves
    /// the agent, refreshes `activeToolSpecs` / `activeToolFamily` /
    /// `activeDecodingParams`, and returns the runner-state effects
    /// (`pushSystemPrompt`, `pushSampling`). Callers wrap with whatever
    /// transcript/vault effects they need.
    private func activate(
        agentId: AgentID,
        currentBackend: BackendPreference,
        settings: InferSettings
    ) async -> [AgentEffect] {
        activeAgentId = agentId

        let agent: any Agent
        if agentId == DefaultAgent.id {
            agent = DefaultAgent(settings: settings)
        } else if let resolved = await registry.agent(id: agentId) {
            agent = resolved
        } else {
            // Registry evicted the agent (e.g. user deleted persona
            // out-of-band between listing refresh and activate). Fall
            // back to Default rather than ending up in a nil-agent state.
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
        // The agent declares which family its tool-call syntax targets.
        // Falls back to whatever the runner reports detecting; if both
        // are nil and we have tools, default to .llama3 so historical
        // behaviour (only llama3 family was supported pre-M4) is
        // preserved for any agent that didn't bother to declare.
        let promptFamily = agent.requirements.templateFamily
            ?? detectedTemplateFamily
            ?? .llama3
        self.activeToolFamily = promptFamily
        let composedPrompt = Self.composeSystemPrompt(
            base: basePrompt,
            tools: tools,
            family: promptFamily
        )
        let params = agent.decodingParams(for: ctx)
        self.activeDecodingParams = params

        return [
            .pushSystemPrompt(composedPrompt.isEmpty ? nil : composedPrompt),
            .pushSampling(
                temperature: params.temperature,
                topP: params.topP,
                seed: settings.seed
            ),
        ]
    }

    /// Combine an agent's base system prompt with a tool-call instruction
    /// block tailored to `family`. When `tools` is empty, returns `base`
    /// unchanged so agents without tools see no behaviour drift.
    ///
    /// Each family gets the exact tag sequence its parser
    /// (`ToolCallParser.findFirstCall`) matches:
    /// - `.llama3`: `<|python_tag|>{JSON}<|eom_id|>`
    /// - `.qwen` / `.hermes`: `<tool_call>{JSON}</tool_call>`
    /// - `.openai`: same Llama-3 wording for now (no in-stream syntax —
    ///   real OpenAI tool-calling is structured outside the assistant
    ///   text and isn't reachable from a local-only deployment).
    public static func composeSystemPrompt(
        base: String,
        tools: [ToolSpec],
        family: TemplateFamily = .llama3
    ) -> String {
        guard !tools.isEmpty else { return base }

        let section = toolPromptSection(family: family, tools: tools)
        if base.isEmpty {
            return section.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return base + section
    }

    private static func toolPromptSection(
        family: TemplateFamily,
        tools: [ToolSpec]
    ) -> String {
        var section = "\n\n# Tools\n\n"

        switch family {
        case .llama3, .openai:
            section += "You have access to the following tools. When you need one, emit EXACTLY one tool call in this format and stop — do not add any text after `<|eom_id|>`:\n\n"
            section += "<|python_tag|>{\"name\": \"<tool name>\", \"parameters\": {<json args>}}<|eom_id|>\n\n"
            section += "The tool's result will be returned to you as an `ipython` role message. Then you continue with your final answer.\n\n"
        case .qwen, .hermes:
            section += "You have access to the following tools. When you need one, emit EXACTLY one tool call wrapped in `<tool_call>` … `</tool_call>` and stop:\n\n"
            section += "<tool_call>\n{\"name\": \"<tool name>\", \"arguments\": {<json args>}}\n</tool_call>\n\n"
            section += "The tool's result will be returned to you in the next turn. Then you continue with your final answer.\n\n"
        }

        section += "Available tools:\n"
        for tool in tools {
            section += "- `\(tool.name)`: \(tool.description)\n"
        }
        section += "\nCall at most one tool per turn. If no tool is needed, answer directly without emitting a tool call."
        return section
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
