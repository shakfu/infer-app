import Foundation

/// UserDefaults keys used by the app. Centralized here so tests and call
/// sites share a single source of truth.
public enum PersistKey {
    public static let backend = "infer.lastBackend"
    public static let systemPrompt = "infer.systemPrompt"
    public static let temperature = "infer.temperature"
    public static let topP = "infer.topP"
    public static let maxTokens = "infer.maxTokens"
    public static let thinkingBudget = "infer.thinkingBudget"
    public static let seed = "infer.seed"
    public static let sidebarOpen = "infer.sidebarOpen"
    public static let sidebarTab = "infer.sidebarTab"
    public static let activeWorkspaceId = "infer.activeWorkspaceId"

    /// Per-workspace toggles stored as UserDefaults keys of the form
    /// `infer.workspace.<id>.<setting>`. Per-workspace defaults live
    /// here so we can add more without a vault migration for each.
    /// Callers use the helper functions below — don't build the key
    /// string by hand at the call site.
    public static func workspaceKey(
        id: Int64,
        setting: String
    ) -> String {
        "infer.workspace.\(id).\(setting)"
    }

    /// Setting names. Extend as new per-workspace toggles arrive.
    public enum WorkspaceSetting: String {
        case hydeEnabled
        case rerankEnabled
    }
    public static let appearance = "infer.appearance"
    public static let ttsEnabled = "infer.ttsEnabled"
    public static let ttsVoiceId = "infer.ttsVoiceId"
    public static let voiceSendPhrase = "infer.voiceSendPhrase"
    public static let continuousVoice = "infer.continuousVoice"
    public static let voiceSendSilenceSeconds = "infer.voiceSendSilenceSeconds"
    public static let bargeInEnabled = "infer.bargeInEnabled"
    public static let ggufDirectory = "infer.ggufDirectory"

    /// Cloud-backend selections. Persisted separately from the local
    /// backends because the model identifier shape is per-provider:
    /// `gpt-5` means nothing to Anthropic, etc. Three model slots so
    /// switching providers in the UI restores the last-used model for
    /// that provider rather than resetting to a default. Custom-endpoint
    /// name + URL persist alongside; the API key is in the keychain
    /// (see `APIKeyStore`), not here.
    public static let cloudProviderKind = "infer.cloud.providerKind"
    public static let cloudOpenAIModel = "infer.cloud.openai.model"
    public static let cloudAnthropicModel = "infer.cloud.anthropic.model"
    public static let cloudCompatModel = "infer.cloud.compat.model"
    public static let cloudCompatName = "infer.cloud.compat.name"
    public static let cloudCompatURL = "infer.cloud.compat.url"

    /// Whether `StepTraceDisclosure` auto-expands while a tool loop is
    /// in flight. Default true (matches pre-M3 behaviour). Users who
    /// find the expanding row noisy can flip it off; the disclosure
    /// then stays collapsed and the user clicks to peek.
    public static let autoExpandAgentTraces = "infer.autoExpandAgentTraces"

    /// Cap on the total number of agent loop steps a single user turn
    /// may consume across an entire composition (M5). Each tool call,
    /// each chain segment, each refine iteration counts. Hitting the
    /// cap terminates with `.budgetExceeded` regardless of which
    /// composition primitive is active. Tuned to be high enough that
    /// normal use never trips it, low enough to bound runaway loops.
    public static let maxAgentSteps = "infer.maxAgentSteps"

    /// Optional explicit path to a `quarto` executable. Empty string /
    /// missing key means "auto-detect" — `QuartoLocator` falls back to
    /// the login-shell PATH and a list of common install locations.
    /// Set this when Quarto is installed somewhere unusual or the user
    /// wants to pin a specific install (e.g. a pre-release).
    public static let quartoPath = "infer.quartoPath"

    /// Optional SearXNG endpoint URL for the `web.search` tool. Empty /
    /// missing key means the tool falls back to DuckDuckGo HTML
    /// scraping (works without setup but fragile to DDG layout
    /// changes). Set this to point at a self-hosted or trusted-public
    /// SearXNG instance for robust JSON-API search.
    public static let searxngEndpoint = "infer.searxngEndpoint"
}

public struct InferSettings: Equatable, Sendable {
    public var systemPrompt: String
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int
    /// Extra tokens allowed for `<think>…</think>` content on top of
    /// `maxTokens`. Reasoning models (Qwen-3, DeepSeek-R1, etc.) emit
    /// thinking that counts against the runner's decode cap but is
    /// stripped from the rendered reply; `maxTokens` caps the net
    /// output, `thinkingBudget` is the invisible allowance. For
    /// non-reasoning models this just widens the hard cap harmlessly.
    /// Bump if reasoning gets truncated mid-thinking on hard
    /// questions; lower to save decode time on simple ones.
    public var thinkingBudget: Int
    /// Total agent loop steps allowed per user turn across an entire
    /// composition. Default 8 — high enough for chain + a couple of
    /// tool calls, low enough that an infinite-loop bug terminates
    /// quickly with `.budgetExceeded`. M5 composition driver decrements
    /// this counter as each segment / step runs.
    public var maxAgentSteps: Int
    /// Optional sampling seed. `nil` means use a random seed (non-deterministic
    /// output). When set, identical prompt + params + seed produces identical
    /// output on a given backend. Stored as a string in UserDefaults since
    /// `UserDefaults` has no native `UInt64` path.
    public var seed: UInt64?
    /// Optional override for the `quarto` executable used by the Quarto
    /// render tool. `nil` (or empty) means "auto-detect" via PATH and
    /// common install locations. Stored as a String so the field can
    /// be edited as text in the UI without nil-aware Bindings.
    public var quartoPath: String?
    /// Optional SearXNG endpoint URL for `web.search`. `nil` (or
    /// empty) means fall back to DuckDuckGo HTML scraping. Same
    /// String-not-URL rationale as `quartoPath`.
    public var searxngEndpoint: String?

    public init(
        systemPrompt: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int,
        thinkingBudget: Int = 4096,
        maxAgentSteps: Int = 8,
        seed: UInt64? = nil,
        quartoPath: String? = nil,
        searxngEndpoint: String? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.thinkingBudget = thinkingBudget
        self.maxAgentSteps = maxAgentSteps
        self.seed = seed
        self.quartoPath = quartoPath
        self.searxngEndpoint = searxngEndpoint
    }

    public static let defaults = InferSettings(
        systemPrompt: "",
        temperature: 0.8,
        topP: 0.95,
        maxTokens: 512,
        thinkingBudget: 4096,
        maxAgentSteps: 8,
        seed: nil,
        quartoPath: nil,
        searxngEndpoint: nil
    )

    public static func load(from defaults: UserDefaults = .standard) -> InferSettings {
        let seedString = defaults.string(forKey: PersistKey.seed)
        let seed: UInt64? = seedString.flatMap { UInt64($0) }
        let quartoRaw = defaults.string(forKey: PersistKey.quartoPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let searxngRaw = defaults.string(forKey: PersistKey.searxngEndpoint)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return InferSettings(
            systemPrompt: defaults.string(forKey: PersistKey.systemPrompt) ?? "",
            temperature: defaults.object(forKey: PersistKey.temperature) as? Double ?? Self.defaults.temperature,
            topP: defaults.object(forKey: PersistKey.topP) as? Double ?? Self.defaults.topP,
            maxTokens: defaults.object(forKey: PersistKey.maxTokens) as? Int ?? Self.defaults.maxTokens,
            thinkingBudget: defaults.object(forKey: PersistKey.thinkingBudget) as? Int ?? Self.defaults.thinkingBudget,
            maxAgentSteps: defaults.object(forKey: PersistKey.maxAgentSteps) as? Int ?? Self.defaults.maxAgentSteps,
            seed: seed,
            quartoPath: (quartoRaw?.isEmpty == false) ? quartoRaw : nil,
            searxngEndpoint: (searxngRaw?.isEmpty == false) ? searxngRaw : nil
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(systemPrompt, forKey: PersistKey.systemPrompt)
        defaults.set(temperature, forKey: PersistKey.temperature)
        defaults.set(topP, forKey: PersistKey.topP)
        defaults.set(maxTokens, forKey: PersistKey.maxTokens)
        defaults.set(thinkingBudget, forKey: PersistKey.thinkingBudget)
        defaults.set(maxAgentSteps, forKey: PersistKey.maxAgentSteps)
        if let seed {
            defaults.set(String(seed), forKey: PersistKey.seed)
        } else {
            defaults.removeObject(forKey: PersistKey.seed)
        }
        if let quartoPath, !quartoPath.isEmpty {
            defaults.set(quartoPath, forKey: PersistKey.quartoPath)
        } else {
            defaults.removeObject(forKey: PersistKey.quartoPath)
        }
        if let searxngEndpoint, !searxngEndpoint.isEmpty {
            defaults.set(searxngEndpoint, forKey: PersistKey.searxngEndpoint)
        } else {
            defaults.removeObject(forKey: PersistKey.searxngEndpoint)
        }
    }
}
