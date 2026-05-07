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
    /// llama.cpp context window for the chat runner. Persisted as Int.
    /// Default 8192. Reload-required: changes only take effect on the
    /// next `LlamaRunner.load`.
    public static let nCtx = "infer.nCtx"
    /// llama.cpp prefill batch size. Persisted as Int. Default 2048.
    /// Reload-required.
    public static let nBatch = "infer.nBatch"
    /// Global default cap (in bytes) on tool output that is fed back to
    /// the model. Per-tool overrides live under
    /// `toolOutputOverrides`. Default 16384 — generous for prose,
    /// tight enough that a 4k-context model survives a few cycles.
    public static let toolOutputDefaultMaxBytes = "infer.toolOutputDefaultMaxBytes"
    /// Per-tool override map for the cap above. Stored as a JSON
    /// `[String: Int]` in UserDefaults so absent keys = use default.
    public static let toolOutputOverrides = "infer.toolOutputOverrides"
    /// Newline-separated list of stop sequences; empty / missing key
    /// means "no stop sequences". Newline is used as the separator
    /// because it's the one byte that can't appear inside a stop
    /// sequence the model ever emits literally — escapes would only
    /// add UI complexity for zero benefit.
    public static let stopSequences = "infer.stopSequences"
    /// OpenAI reasoning effort: one of CloudGenerationParams.ReasoningEffort
    /// raw values, or empty / missing for "let the model default".
    /// Only takes effect on o-series + gpt-5 models — other models
    /// silently ignore.
    public static let reasoningEffort = "infer.cloud.reasoningEffort"
    /// OpenAI gpt-5 verbosity: low | medium | high, or empty for default.
    public static let verbosity = "infer.cloud.verbosity"
    /// OpenAI frequency_penalty (-2.0..2.0). Stored as Double; missing
    /// key omits the field from the request.
    public static let frequencyPenalty = "infer.cloud.frequencyPenalty"
    /// OpenAI presence_penalty (-2.0..2.0). Same shape as frequencyPenalty.
    public static let presencePenalty = "infer.cloud.presencePenalty"
    /// Provider-specific service tier string. OpenAI accepts
    /// auto|default|flex|scale|priority; Anthropic accepts auto|standard_only.
    /// Stored as a single field because the runtime never compares values
    /// across providers — each client just forwards the string.
    public static let serviceTier = "infer.cloud.serviceTier"
    /// OpenAI prompt_cache_key. Free-form opaque tag the user picks.
    /// Empty / missing = no prompt-cache hint sent.
    public static let promptCacheKey = "infer.cloud.promptCacheKey"
    /// Anthropic prompt-caching toggle. When true, the system prompt is
    /// tagged `cache_control: ephemeral` on each request so the cached
    /// rate applies. Anthropic's caching is opt-in per content block;
    /// OpenAI's is keyed by promptCacheKey above — both surfaces are
    /// exposed because they don't unify cleanly.
    public static let anthropicPromptCaching = "infer.cloud.anthropicPromptCaching"
    /// Whether to enable Anthropic extended thinking on cloud. Gates the
    /// projection of `thinkingBudget` into the cloud request — local
    /// runners always honour `thinkingBudget` as a widening allowance,
    /// but cloud's Anthropic extended-thinking feature changes sampling
    /// semantics (forces temperature=1.0) so it must be explicit.
    public static let cloudExtendedThinkingEnabled = "infer.cloud.extendedThinkingEnabled"
    public static let sidebarOpen = "infer.sidebarOpen"
    /// Visibility of the left wiki sidebar (per-workspace markdown
    /// pages + pin toggles). Independent of `sidebarOpen` so a user
    /// can collapse one without the other. Defaults to true on first
    /// launch so the wiki feature is discoverable.
    public static let wikiSidebarOpen = "infer.wikiSidebarOpen"
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
    public static let cloudOpenRouterModel = "infer.cloud.openrouter.model"
    public static let cloudCompatModel = "infer.cloud.compat.model"
    /// Preset id (`compat:<slug>`) when the active picker selection is
    /// a preloaded compat endpoint from `cloud-providers.json`. Empty
    /// string = no preset (the user typed a name + URL by hand into
    /// the OpenAI-compatible (custom) entry). Read alongside
    /// `cloudProviderKind` to disambiguate.
    public static let cloudCompatPresetId = "infer.cloud.compat.presetId"
    public static let cloudCompatName = "infer.cloud.compat.name"
    public static let cloudCompatURL = "infer.cloud.compat.url"

    /// Stable Diffusion (image generation) state. Lives outside the
    /// `Backend` enum because image gen isn't a chat backend — it's a
    /// dedicated panel with its own lifecycle. Model input is either a
    /// local `.safetensors` / `.gguf` path, an HF id of the form
    /// `repo/path/to/file.safetensors`, or an https URL.
    /// All-in-one checkpoint (SD 1.x/2.x/SDXL/Flux fp8 single-file).
    public static let sdModelInput = "infer.sd.modelInput"
    /// Diffusion-only file. Used when the model ships separately from
    /// its VAE + text encoder(s) — Z-Image, Flux full multi-file.
    public static let sdDiffusionModelInput = "infer.sd.diffusionModelInput"
    public static let sdVAEInput = "infer.sd.vaeInput"
    /// Text encoder for Z-Image (a small LLM, e.g. Qwen3-4B-Q8_0.gguf).
    public static let sdLLMInput = "infer.sd.llmInput"
    /// T5 text encoder for Flux multi-file.
    public static let sdT5XXLInput = "infer.sd.t5xxlInput"
    /// CLIP-L text encoder for Flux multi-file.
    public static let sdClipLInput = "infer.sd.clipLInput"
    /// `offload_params_to_cpu` — needed on lower-RAM machines for Z-Image
    /// and large Flux models. Maps to sd-cpp's `--offload-to-cpu`.
    public static let sdOffloadToCPU = "infer.sd.offloadToCPU"
    /// CPU thread count for sd-cpp's BLAS / on-CPU model paths. Stored
    /// as Int; 0 = "auto" (use half of `activeProcessorCount`). Lower
    /// values trade SD throughput for system responsiveness during
    /// generation — `activeProcessorCount - 1` (the prior default) is
    /// enough to peg the WindowServer.
    public static let sdNThreads = "infer.sd.nThreads"
    /// JSON-encoded `[String]` of model identifiers (trimmed primary
    /// input — local path or HF reference) the user has explicitly
    /// acknowledged as "load anyway" past the low-spec heavy-model
    /// gate. Stored as a Data blob via JSONEncoder so the array is
    /// future-extensible.
    public static let sdAcknowledgedHeavyModels = "infer.sd.acknowledgedHeavyModels"

    /// Token budget for always-injected wiki context. Stored as Int;
    /// 0 (default for unset Int in UserDefaults) means "use built-in
    /// default" (8k). The wiki composes pinned pages + their
    /// transitive `[[wikilinks]]` and stops adding pages once this
    /// cap would be exceeded; pinned roots bypass the cap.
    public static let wikiBudgetTokens = "infer.wiki.budgetTokens"
    public static let sdPrompt = "infer.sd.prompt"
    public static let sdNegativePrompt = "infer.sd.negativePrompt"
    public static let sdWidth = "infer.sd.width"
    public static let sdHeight = "infer.sd.height"
    public static let sdSteps = "infer.sd.steps"
    public static let sdCfgScale = "infer.sd.cfgScale"
    public static let sdSampler = "infer.sd.sampler"
    public static let sdSeed = "infer.sd.seed"

    /// Image-generation backend (Local SD or cloud OpenAI). Independent
    /// of the chat backend; an image-gen user might run cloud-only
    /// while chat is local, or the reverse. Persisted as the
    /// `ImageBackend` enum's raw value.
    public static let imageBackend = "infer.image.backend"
    /// OpenAI image-gen params (gpt-image-1). Discrete sets — the API
    /// rejects arbitrary sizes, so the picker ships a fixed list.
    public static let openaiImageSize = "infer.image.openai.size"
    public static let openaiImageQuality = "infer.image.openai.quality"
    public static let openaiImageFormat = "infer.image.openai.format"
    public static let openaiImageBackground = "infer.image.openai.background"

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
    /// Llama.cpp chat-runner context window. Reload-required. Default
    /// 8192; the UI clamps to the loaded model's `n_ctx_train`.
    public var nCtx: Int
    /// Llama.cpp prefill batch size. Reload-required. Default 2048.
    public var nBatch: Int
    /// Default cap on a tool's output bytes when no per-tool override
    /// is set. Default 16 KB.
    public var toolOutputDefaultMaxBytes: Int
    /// Per-tool overrides keyed by `ToolName`. Empty = every tool uses
    /// the default. A value of 0 means "no cap".
    public var toolOutputOverrides: [String: Int]
    /// Optional override for the `quarto` executable used by the Quarto
    /// render tool. `nil` (or empty) means "auto-detect" via PATH and
    /// common install locations. Stored as a String so the field can
    /// be edited as text in the UI without nil-aware Bindings.
    public var quartoPath: String?
    /// Optional SearXNG endpoint URL for `web.search`. `nil` (or
    /// empty) means fall back to DuckDuckGo HTML scraping. Same
    /// String-not-URL rationale as `quartoPath`.
    public var searxngEndpoint: String?

    /// User-configured stop sequences. Forwarded to both cloud providers
    /// (OpenAI: `stop`, Anthropic: `stop_sequences`) and to the local
    /// runners once their stop-sequence wiring lands. Empty = none.
    public var stopSequences: [String]
    /// OpenAI reasoning effort. Persisted as the enum's raw value; nil
    /// or unrecognised string = "let the model default".
    public var reasoningEffort: CloudGenerationParams.ReasoningEffort?
    /// OpenAI gpt-5 verbosity.
    public var verbosity: CloudGenerationParams.Verbosity?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var serviceTier: String?
    public var promptCacheKey: String?
    public var anthropicPromptCaching: Bool
    /// Gate for projecting `thinkingBudget` into Anthropic's extended
    /// thinking feature on cloud. Off by default so existing users
    /// don't suddenly hit the temperature-clamp side effect.
    public var cloudExtendedThinkingEnabled: Bool

    public init(
        systemPrompt: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int,
        thinkingBudget: Int = 4096,
        maxAgentSteps: Int = 8,
        seed: UInt64? = nil,
        nCtx: Int = 8192,
        nBatch: Int = 2048,
        toolOutputDefaultMaxBytes: Int = 16_384,
        toolOutputOverrides: [String: Int] = [:],
        quartoPath: String? = nil,
        searxngEndpoint: String? = nil,
        stopSequences: [String] = [],
        reasoningEffort: CloudGenerationParams.ReasoningEffort? = nil,
        verbosity: CloudGenerationParams.Verbosity? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        serviceTier: String? = nil,
        promptCacheKey: String? = nil,
        anthropicPromptCaching: Bool = false,
        cloudExtendedThinkingEnabled: Bool = false
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.thinkingBudget = thinkingBudget
        self.maxAgentSteps = maxAgentSteps
        self.seed = seed
        self.nCtx = nCtx
        self.nBatch = nBatch
        self.toolOutputDefaultMaxBytes = toolOutputDefaultMaxBytes
        self.toolOutputOverrides = toolOutputOverrides
        self.quartoPath = quartoPath
        self.searxngEndpoint = searxngEndpoint
        self.stopSequences = stopSequences
        self.reasoningEffort = reasoningEffort
        self.verbosity = verbosity
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.serviceTier = serviceTier
        self.promptCacheKey = promptCacheKey
        self.anthropicPromptCaching = anthropicPromptCaching
        self.cloudExtendedThinkingEnabled = cloudExtendedThinkingEnabled
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
        let stopRaw = defaults.string(forKey: PersistKey.stopSequences) ?? ""
        let stops = stopRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let effort = (defaults.string(forKey: PersistKey.reasoningEffort))
            .flatMap(CloudGenerationParams.ReasoningEffort.init(rawValue:))
        let verbosity = (defaults.string(forKey: PersistKey.verbosity))
            .flatMap(CloudGenerationParams.Verbosity.init(rawValue:))
        let serviceTierRaw = defaults.string(forKey: PersistKey.serviceTier)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKeyRaw = defaults.string(forKey: PersistKey.promptCacheKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let toolOverridesRaw = defaults.string(forKey: PersistKey.toolOutputOverrides)
        let toolOverrides: [String: Int] = toolOverridesRaw
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] }
            ?? [:]
        return InferSettings(
            systemPrompt: defaults.string(forKey: PersistKey.systemPrompt) ?? "",
            temperature: defaults.object(forKey: PersistKey.temperature) as? Double ?? Self.defaults.temperature,
            topP: defaults.object(forKey: PersistKey.topP) as? Double ?? Self.defaults.topP,
            maxTokens: defaults.object(forKey: PersistKey.maxTokens) as? Int ?? Self.defaults.maxTokens,
            thinkingBudget: defaults.object(forKey: PersistKey.thinkingBudget) as? Int ?? Self.defaults.thinkingBudget,
            maxAgentSteps: defaults.object(forKey: PersistKey.maxAgentSteps) as? Int ?? Self.defaults.maxAgentSteps,
            seed: seed,
            nCtx: defaults.object(forKey: PersistKey.nCtx) as? Int ?? Self.defaults.nCtx,
            nBatch: defaults.object(forKey: PersistKey.nBatch) as? Int ?? Self.defaults.nBatch,
            toolOutputDefaultMaxBytes: defaults.object(forKey: PersistKey.toolOutputDefaultMaxBytes) as? Int ?? Self.defaults.toolOutputDefaultMaxBytes,
            toolOutputOverrides: toolOverrides,
            quartoPath: (quartoRaw?.isEmpty == false) ? quartoRaw : nil,
            searxngEndpoint: (searxngRaw?.isEmpty == false) ? searxngRaw : nil,
            stopSequences: stops,
            reasoningEffort: effort,
            verbosity: verbosity,
            frequencyPenalty: defaults.object(forKey: PersistKey.frequencyPenalty) as? Double,
            presencePenalty: defaults.object(forKey: PersistKey.presencePenalty) as? Double,
            serviceTier: (serviceTierRaw?.isEmpty == false) ? serviceTierRaw : nil,
            promptCacheKey: (cacheKeyRaw?.isEmpty == false) ? cacheKeyRaw : nil,
            anthropicPromptCaching: defaults.bool(forKey: PersistKey.anthropicPromptCaching),
            cloudExtendedThinkingEnabled: defaults.bool(forKey: PersistKey.cloudExtendedThinkingEnabled)
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
        defaults.set(nCtx, forKey: PersistKey.nCtx)
        defaults.set(nBatch, forKey: PersistKey.nBatch)
        defaults.set(toolOutputDefaultMaxBytes, forKey: PersistKey.toolOutputDefaultMaxBytes)
        if toolOutputOverrides.isEmpty {
            defaults.removeObject(forKey: PersistKey.toolOutputOverrides)
        } else if let data = try? JSONSerialization.data(withJSONObject: toolOutputOverrides),
                  let s = String(data: data, encoding: .utf8) {
            defaults.set(s, forKey: PersistKey.toolOutputOverrides)
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
        if stopSequences.isEmpty {
            defaults.removeObject(forKey: PersistKey.stopSequences)
        } else {
            defaults.set(stopSequences.joined(separator: "\n"), forKey: PersistKey.stopSequences)
        }
        if let reasoningEffort {
            defaults.set(reasoningEffort.rawValue, forKey: PersistKey.reasoningEffort)
        } else {
            defaults.removeObject(forKey: PersistKey.reasoningEffort)
        }
        if let verbosity {
            defaults.set(verbosity.rawValue, forKey: PersistKey.verbosity)
        } else {
            defaults.removeObject(forKey: PersistKey.verbosity)
        }
        if let frequencyPenalty {
            defaults.set(frequencyPenalty, forKey: PersistKey.frequencyPenalty)
        } else {
            defaults.removeObject(forKey: PersistKey.frequencyPenalty)
        }
        if let presencePenalty {
            defaults.set(presencePenalty, forKey: PersistKey.presencePenalty)
        } else {
            defaults.removeObject(forKey: PersistKey.presencePenalty)
        }
        if let serviceTier, !serviceTier.isEmpty {
            defaults.set(serviceTier, forKey: PersistKey.serviceTier)
        } else {
            defaults.removeObject(forKey: PersistKey.serviceTier)
        }
        if let promptCacheKey, !promptCacheKey.isEmpty {
            defaults.set(promptCacheKey, forKey: PersistKey.promptCacheKey)
        } else {
            defaults.removeObject(forKey: PersistKey.promptCacheKey)
        }
        defaults.set(anthropicPromptCaching, forKey: PersistKey.anthropicPromptCaching)
        defaults.set(cloudExtendedThinkingEnabled, forKey: PersistKey.cloudExtendedThinkingEnabled)
    }

    /// Resolve the byte cap that should apply to a given tool's
    /// output. Per-tool override wins; otherwise the global default.
    /// `0` is the user-visible "no cap" sentinel and is propagated
    /// verbatim — tools interpret it.
    public func toolOutputCap(for toolName: String) -> Int {
        if let override = toolOutputOverrides[toolName] {
            return override
        }
        return toolOutputDefaultMaxBytes
    }

    /// Project these settings into a `CloudGenerationParams` for the
    /// cloud runner. Pure projection — no policy or model-id awareness;
    /// per-provider guards live inside each `CloudClient` impl.
    public func cloudParams() -> CloudGenerationParams {
        CloudGenerationParams(
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            seed: seed,
            stopSequences: stopSequences,
            thinkingBudgetTokens: (cloudExtendedThinkingEnabled && thinkingBudget > 0) ? thinkingBudget : nil,
            reasoningEffort: reasoningEffort,
            promptCacheKey: promptCacheKey,
            anthropicPromptCaching: anthropicPromptCaching,
            verbosity: verbosity,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            serviceTier: serviceTier
        )
    }
}
