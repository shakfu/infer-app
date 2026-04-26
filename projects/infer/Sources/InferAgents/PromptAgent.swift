import Foundation
import InferCore

/// JSON-backed persona or agent. Reads a JSON file on disk and conforms to
/// `Agent` with static implementations of every hook. This is the
/// "persona pack" / "agent pack" case. Users and plugins can author these
/// without touching Swift.
///
/// The schema is itself a versioned, user-facing API. The file's
/// `schemaVersion` drives forward-compatible parsing:
/// - Unknown fields in a known major version are ignored (`Codable`'s
///   default behaviour plus our explicit `decodeIfPresent` path for
///   optional fields).
/// - An unknown `schemaVersion` rejects the file with
///   `AgentError.unsupportedSchemaVersion` so the Agents tab can show the
///   user a "file requires a newer Infer" reason row instead of silently
///   loading a malformed agent.
///
/// Schema v2 (current) adds the `kind` discriminator (persona vs agent),
/// the optional `contextPath` markdown sidecar, and forward-declares the
/// composition fields (`chain`, `orchestrator`) that v3 will activate.
/// See `docs/dev/agent_kinds.md`.
public struct PromptAgent: Agent, Codable, Equatable {
    /// Current persona schema major version. Breaking renames bump this
    /// and keep the prior major loadable for one release.
    public static let currentSchemaVersion = 3
    public static let supportedSchemaVersions: Set<Int> = [1, 2, 3]

    public let schemaVersion: Int
    public let id: AgentID
    public let kind: AgentKind
    public let metadata: AgentMetadata
    public let requirements: AgentRequirements

    /// Stored default decoding params. Exposed to the protocol via
    /// `decodingParams(for:)`; separate property name avoids the method
    /// shadowing that would otherwise conflict.
    public let defaultDecodingParams: DecodingParams

    /// Combined system prompt. When `contextPath` is present at decode
    /// time, the sidecar's markdown is read and concatenated onto the
    /// authored `systemPrompt` before this property is stored. Round-trip
    /// encoding writes back the original `systemPrompt` and `contextPath`
    /// separately (see `Codable` impl below) so files don't grow on save.
    public let promptText: String

    /// Authored system prompt, sans sidecar. Held separately from
    /// `promptText` so encoding round-trips cleanly.
    public let authoredSystemPrompt: String

    /// Markdown sidecar path relative to the JSON file's directory.
    /// Resolved at decode time; rejected on path traversal.
    public let contextPath: String?

    /// Composition fields (schema v3). Structural validation happens
    /// at decode; cross-agent existence + cycle detection runs at
    /// registry-load time once every file is loaded. Runtime semantics
    /// — actually executing chain/fallback/orchestrator — land in
    /// M5a-runtime via `CompositionController`.
    public let chain: [AgentID]?
    public let fallback: [AgentID]?
    public let orchestrator: OrchestratorSpec?
    public let budget: BudgetSpec?
    public let branch: BranchSpec?
    public let refine: RefineSpec?

    public struct OrchestratorSpec: Codable, Equatable, Sendable {
        public let router: AgentID
        public let candidates: [AgentID]
    }

    /// Per-composition step budget overriding `InferSettings.maxAgentSteps`.
    /// `onBudgetLow` is reserved for `agent_composition.md`'s eventual
    /// "low-water mark" callback; for now it's just a string the
    /// runtime is free to ignore.
    public struct BudgetSpec: Codable, Equatable, Sendable {
        public let maxSteps: Int?
        public let onBudgetLow: String?
    }

    /// Conditional dispatch (M5b). Run `predicate` against the previous
    /// segment's outcome — typically a probe agent that classifies the
    /// user request — and dispatch to `then` if true, `else` if false.
    /// `probe` is optional: when set, it runs first and the predicate
    /// evaluates against its outcome; when unset, the predicate
    /// evaluates against the user's text directly (treated as a
    /// `.completed` outcome with the user input).
    public struct BranchSpec: Codable, Equatable, Sendable {
        public let probe: AgentID?
        public let predicate: Predicate
        public let then: AgentID
        public let `else`: AgentID
    }

    /// Producer-critic refinement loop (M5b). The producer drafts an
    /// answer; the critic reviews it. If the critic's outcome matches
    /// `acceptWhen`, the producer's last draft is the final answer.
    /// Otherwise the critic's output feeds back to the producer for
    /// another round, up to `maxIterations`. Hitting the iteration cap
    /// without acceptance returns the producer's last draft anyway —
    /// "good enough" beats "no answer."
    public struct RefineSpec: Codable, Equatable, Sendable {
        public let producer: AgentID
        public let critic: AgentID
        public let maxIterations: Int
        public let acceptWhen: Predicate
    }

    public init(
        id: AgentID,
        kind: AgentKind = .persona,
        metadata: AgentMetadata,
        requirements: AgentRequirements = AgentRequirements(),
        decodingParams: DecodingParams = DecodingParams(from: .defaults),
        systemPrompt: String,
        contextPath: String? = nil,
        chain: [AgentID]? = nil,
        fallback: [AgentID]? = nil,
        orchestrator: OrchestratorSpec? = nil,
        budget: BudgetSpec? = nil,
        branch: BranchSpec? = nil,
        refine: RefineSpec? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.kind = kind
        self.metadata = metadata
        self.requirements = requirements
        self.defaultDecodingParams = decodingParams
        self.promptText = systemPrompt
        self.authoredSystemPrompt = systemPrompt
        self.contextPath = contextPath
        self.chain = chain
        self.fallback = fallback
        self.orchestrator = orchestrator
        self.budget = budget
        self.branch = branch
        self.refine = refine
    }

    public func decodingParams(for context: AgentContext) -> DecodingParams {
        defaultDecodingParams
    }

    public func systemPrompt(for context: AgentContext) async throws -> String {
        promptText
    }

    /// Belt-and-braces runtime guarantee: a persona never sees tools.
    /// The loader rejects `kind: persona` with non-empty `toolsAllow`, but
    /// this override defends against any other path (synthesised personas,
    /// future loader bugs, mutation-by-test) that might leak tools to a
    /// persona at runtime. See `docs/dev/agent_kinds.md` open question 2.
    public func toolsAvailable(for context: AgentContext) async throws -> [ToolSpec] {
        guard kind != .persona else { return [] }
        let allow = Set(requirements.toolsAllow)
        let deny = Set(requirements.toolsDeny)
        return context.tools.tools.filter { spec in
            guard !deny.contains(spec.name) else { return false }
            return allow.isEmpty || allow.contains(spec.name)
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case kind
        case metadata
        case requirements
        case decodingParams
        case systemPrompt
        case contextPath
        case chain
        case fallback
        case orchestrator
        case budget
        case branch
        case refine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Rule 1: known schema version.
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard Self.supportedSchemaVersions.contains(version) else {
            throw AgentError.unsupportedSchemaVersion(version)
        }

        let id = try c.decode(AgentID.self, forKey: .id)
        guard !id.isEmpty else {
            throw AgentError.invalidPersona("id is empty")
        }
        let metadata = try c.decode(AgentMetadata.self, forKey: .metadata)
        guard !metadata.name.isEmpty else {
            throw AgentError.invalidPersona("metadata.name is empty")
        }

        let requirements = try c.decodeIfPresent(AgentRequirements.self, forKey: .requirements)
            ?? AgentRequirements()
        let chain = try c.decodeIfPresent([AgentID].self, forKey: .chain)
        let fallback = try c.decodeIfPresent([AgentID].self, forKey: .fallback)
        let orchestrator = try c.decodeIfPresent(OrchestratorSpec.self, forKey: .orchestrator)
        let budget = try c.decodeIfPresent(BudgetSpec.self, forKey: .budget)
        let branch = try c.decodeIfPresent(BranchSpec.self, forKey: .branch)
        let refine = try c.decodeIfPresent(RefineSpec.self, forKey: .refine)

        // Rule 2: kind present (or auto-derived for v1).
        let kind: AgentKind
        if let declared = try c.decodeIfPresent(AgentKind.self, forKey: .kind) {
            kind = declared
        } else if version == 1 {
            // v1 auto-classification: tools or composition ⇒ agent.
            let hasTools = !requirements.toolsAllow.isEmpty
            let hasComposition = (chain?.isEmpty == false)
                || (fallback?.isEmpty == false)
                || orchestrator != nil
                || branch != nil
                || refine != nil
            kind = (hasTools || hasComposition) ? .agent : .persona
        } else {
            throw AgentError.invalidPersona("kind is required for schemaVersion \(version)")
        }

        // Rule 3: persona must not declare tools or composition.
        if kind == .persona {
            if !requirements.toolsAllow.isEmpty {
                throw AgentError.invalidPersona(
                    "persona declares tools — use kind: \"agent\""
                )
            }
            if chain?.isEmpty == false
                || fallback?.isEmpty == false
                || orchestrator != nil
                || budget != nil
                || branch != nil
                || refine != nil {
                throw AgentError.invalidPersona(
                    "persona declares composition — use kind: \"agent\""
                )
            }
        }

        // Rule 4: agent should declare at least one capability. Empty
        // agents load with no error here — `agent_kinds.md` §"Validation
        // rules" 4 says load with a warning, not a rejection. Warning
        // surfacing is the loader's job (see `AgentRegistry`).

        // Rule 5: structural validation of composition references.
        // Cross-registry existence + cycle checks happen at registry-load
        // time once all files are in.
        if let chain, chain.contains(where: { $0.isEmpty }) {
            throw AgentError.invalidPersona("chain contains empty agent id")
        }
        if let fallback, fallback.contains(where: { $0.isEmpty }) {
            throw AgentError.invalidPersona("fallback contains empty agent id")
        }
        if let budget, let max = budget.maxSteps, max <= 0 {
            throw AgentError.invalidPersona("budget.maxSteps must be positive")
        }
        if let branch {
            if branch.then.isEmpty || branch.else.isEmpty {
                throw AgentError.invalidPersona("branch.then / branch.else must be non-empty")
            }
            if let probe = branch.probe, probe.isEmpty {
                throw AgentError.invalidPersona("branch.probe must be non-empty when set")
            }
        }
        if let refine {
            if refine.producer.isEmpty || refine.critic.isEmpty {
                throw AgentError.invalidPersona("refine.producer / refine.critic must be non-empty")
            }
            if refine.maxIterations <= 0 {
                throw AgentError.invalidPersona("refine.maxIterations must be positive")
            }
        }
        if let orch = orchestrator {
            if orch.router.isEmpty {
                throw AgentError.invalidPersona("orchestrator.router is empty")
            }
            if orch.candidates.isEmpty {
                throw AgentError.invalidPersona("orchestrator.candidates is empty")
            }
            if orch.candidates.contains(where: { $0.isEmpty }) {
                throw AgentError.invalidPersona(
                    "orchestrator.candidates contains empty agent id"
                )
            }
        }

        let authoredPrompt = try c.decode(String.self, forKey: .systemPrompt)
        let contextPath = try c.decodeIfPresent(String.self, forKey: .contextPath)

        // Rule 5 (path traversal) + sidecar load. `userInfo[.personaSourceURL]`
        // is set by the loader (`AgentRegistry.loadPersonas` /
        // `AgentController.loadFirstPartyPersonas`) so the sidecar can be
        // resolved relative to the JSON file. When unset (e.g. in-memory
        // decode from tests), `contextPath` is rejected because there's
        // no anchor.
        var combinedPrompt = authoredPrompt
        if let rel = contextPath {
            guard !rel.isEmpty else {
                throw AgentError.invalidPersona("contextPath is empty")
            }
            try Self.rejectPathTraversal(rel)
            guard let baseURL = decoder.userInfo[.personaSourceURL] as? URL else {
                throw AgentError.invalidPersona(
                    "contextPath set but loader did not provide a source URL"
                )
            }
            let sidecar = baseURL
                .deletingLastPathComponent()
                .appendingPathComponent(rel)
            do {
                let contents = try String(contentsOf: sidecar, encoding: .utf8)
                if combinedPrompt.isEmpty {
                    combinedPrompt = contents
                } else {
                    combinedPrompt = authoredPrompt + "\n\n" + contents
                }
            } catch {
                throw AgentError.invalidPersona(
                    "contextPath not found: \(rel)"
                )
            }
        }

        self.schemaVersion = version
        self.id = id
        self.kind = kind
        self.metadata = metadata
        self.requirements = requirements
        self.defaultDecodingParams = (try? c.decode(DecodingParams.self, forKey: .decodingParams))
            ?? DecodingParams(from: .defaults)
        self.promptText = combinedPrompt
        self.authoredSystemPrompt = authoredPrompt
        self.contextPath = contextPath
        self.chain = chain
        self.fallback = fallback
        self.orchestrator = orchestrator
        self.budget = budget
        self.branch = branch
        self.refine = refine
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(requirements, forKey: .requirements)
        try c.encode(defaultDecodingParams, forKey: .decodingParams)
        try c.encode(authoredSystemPrompt, forKey: .systemPrompt)
        try c.encodeIfPresent(contextPath, forKey: .contextPath)
        try c.encodeIfPresent(chain, forKey: .chain)
        try c.encodeIfPresent(fallback, forKey: .fallback)
        try c.encodeIfPresent(orchestrator, forKey: .orchestrator)
        try c.encodeIfPresent(budget, forKey: .budget)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(refine, forKey: .refine)
    }

    /// Reject `..` segments and absolute paths. Symlinks are not resolved
    /// here — defence-in-depth lives at the file-read layer.
    private static func rejectPathTraversal(_ path: String) throws {
        if path.hasPrefix("/") {
            throw AgentError.invalidPersona(
                "contextPath must be relative: \(path)"
            )
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0 == ".." }) {
            throw AgentError.invalidPersona(
                "contextPath must not traverse parent directories: \(path)"
            )
        }
    }
}

public extension CodingUserInfoKey {
    /// Set by the persona loader before decoding so `contextPath` can be
    /// resolved relative to the JSON file's directory. Decoders run from
    /// raw `Data` (no source URL) ignore `contextPath` if unset and reject
    /// the file when one is declared.
    static let personaSourceURL = CodingUserInfoKey(rawValue: "infer.personaSourceURL")!
}
