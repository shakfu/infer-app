import Foundation

/// Identity of a cloud chat backend. Four flavors:
///
/// - `.openai` — canonical OpenAI at `api.openai.com`. Bearer-token auth.
/// - `.anthropic` — canonical Anthropic at `api.anthropic.com`. `x-api-key` auth.
/// - `.openrouter` — OpenRouter at `openrouter.ai/api/v1`. OpenAI-shaped
///   wire format (drop-in for the OpenAI SDK, per their docs), but model
///   ids carry a namespace prefix (`openai/gpt-5.2`,
///   `anthropic/claude-opus-4-7`, `meta-llama/llama-4`, …) and the env var
///   convention is `OPENROUTER_API_KEY`. Modeled as a first-class case
///   rather than the generic `.openaiCompatible` so the user gets a
///   one-click "OpenRouter" picker entry, a curated recommended-model
///   list, and the dedicated env var fallback without typing a base URL.
/// - `.openaiCompatible` — user-supplied base URL plus a display name. Reuses
///   the OpenAI wire format (`/v1/chat/completions` + SSE), so any provider
///   that speaks it (Ollama, LM Studio, Groq, Together, …) drops in by
///   overriding the URL. The `name` is what the user sees in the backend
///   picker; it also feeds the keychain account string so multiple compat
///   endpoints don't share credentials.
public enum CloudProvider: Sendable, Hashable {
    case openai
    case anthropic
    case openrouter
    case openaiCompatible(name: String, baseURL: URL)

    /// Canonical base URL for OpenRouter. Used by the client factory so
    /// the route is a single source of truth, not duplicated at the
    /// `OpenAIClient` construction site.
    public static let openRouterBaseURL = URL(string: "https://openrouter.ai/api/v1")!

    /// Human-readable label for UI surfaces.
    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openrouter: return "OpenRouter"
        case .openaiCompatible(let name, _): return name
        }
    }

    /// Account string used by `APIKeyStore` so each provider — including
    /// each compat endpoint by name — gets its own keychain item.
    public var keychainAccount: String {
        switch self {
        case .openai: return "openai"
        case .anthropic: return "anthropic"
        case .openrouter: return "openrouter"
        case .openaiCompatible(let name, _):
            return "compat." + Self.normalizeAccountSuffix(name)
        }
    }

    /// Process-environment variable consulted as a developer fallback when
    /// no keychain item exists. `nil` for compat endpoints because there's
    /// no canonical env var per third-party provider — users configure
    /// those interactively.
    public var envVarName: String? {
        switch self {
        case .openai: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openrouter: return "OPENROUTER_API_KEY"
        case .openaiCompatible: return nil
        }
    }

    /// Lowercases and replaces non-`[a-z0-9._-]` runs with `-` so the
    /// keychain account stays printable and stable. Two endpoints whose
    /// names normalize to the same suffix will share a keychain slot;
    /// callers that allow free-form names should validate uniqueness up
    /// front.
    private static func normalizeAccountSuffix(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        let lowered = s.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lowered {
            if allowed.contains(ch) {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Persistence-friendly discriminator over `CloudProvider`. `CloudProvider`
/// itself carries associated values (the compat URL + name), which makes it
/// awkward to bind to a SwiftUI `Picker` and to round-trip through
/// `UserDefaults`. The kind is the dropdown half; the URL + name are stored
/// alongside as plain strings and reassembled at use-site.
public enum CloudProviderKind: String, CaseIterable, Identifiable, Sendable {
    case openai
    case anthropic
    case openrouter
    case openaiCompatible

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openrouter: return "OpenRouter"
        case .openaiCompatible: return "OpenAI-compatible"
        }
    }
}

extension CloudProvider {
    public var kind: CloudProviderKind {
        switch self {
        case .openai: return .openai
        case .anthropic: return .anthropic
        case .openrouter: return .openrouter
        case .openaiCompatible: return .openaiCompatible
        }
    }
}

/// Curated list of model ids surfaced as suggestions in the model picker.
/// Free-text input is still accepted — this is just the dropdown half of
/// the hybrid UX.
///
/// Layered load order at first access (cached for the process lifetime):
///
/// 1. **User override** at `~/Library/Application Support/Infer/cloud-models.json`.
///    If present and parseable, replaces the bundled defaults wholesale.
///    Lets users curate their own picker without rebuilding the app — point
///    your team's allowed-models list here, prune away models you never use,
///    add private aliases, etc.
/// 2. **Bundled defaults** at `Resources/CloudModels.json` (this target's
///    `Bundle.module`). Edited and shipped with each release.
/// 3. **Hardcoded fallback** in `defaultLists` (this file). Safety net for
///    a corrupt / missing JSON; mirrors what was hardcoded before the
///    JSON migration.
///
/// Convention: the same loader pattern (override → bundled → hardcoded)
/// is the right shape for every future configurable-via-JSON entity in
/// the project (cloud-providers.json, etc.). Repeating it preserves the
/// "drop a file in Application Support to customize" UX across the app.
public enum CloudRecommendedModels {
    public static func suggestions(for provider: CloudProvider) -> [String] {
        let lists = effectiveLists()
        switch provider {
        case .openai: return lists.openai
        case .anthropic: return lists.anthropic
        case .openrouter: return lists.openrouter
        case .openaiCompatible: return []
        }
    }

    /// First-suggested model id for the given provider kind, or empty
    /// string if the list is empty or the provider has no suggestions.
    /// Used to seed per-provider model fields on first launch (when no
    /// `UserDefaults` value exists yet) so the picker isn't blank.
    public static func defaultModelId(for kind: CloudProviderKind) -> String {
        let lists = effectiveLists()
        switch kind {
        case .openai: return lists.openai.first ?? ""
        case .anthropic: return lists.anthropic.first ?? ""
        case .openrouter: return lists.openrouter.first ?? ""
        case .openaiCompatible: return ""
        }
    }

    /// Fully-resolved (non-optional) lists used by `suggestions(for:)`.
    /// Never partial — every field is guaranteed populated, either from
    /// the layered load or the hardcoded fallback.
    private struct ResolvedLists {
        var openai: [String]
        var anthropic: [String]
        var openrouter: [String]
    }

    /// Pinned-to-code defaults. Used when neither the user override nor
    /// the bundled JSON load successfully — pure-Swift, can't fail.
    /// Values mirror what the bundled `CloudModels.json` ships with at
    /// release time; if the two drift, the JSON wins (it's loaded first).
    private static let defaultLists = ResolvedLists(
        openai: [
            "gpt-5.4-nano",
            "gpt-5.4-mini",
            "gpt-5.4",
            "gpt-5.4-pro",
            "gpt-5.5",
            "gpt-5.5-pro",
        ],
        anthropic: [
            "claude-opus-4-7",
            "claude-sonnet-4-6",
            "claude-haiku-4-5",
        ],
        openrouter: [
            "deepseek/deepseek-v3.2",
            "deepseek/deepseek-v4-flash",
            "deepseek/deepseek-v4-pro",
            "google/gemini-2.5-flash",
            "google/gemini-2.5-flash-lite",
            "google/gemini-3-flash-preview",
            "google/gemma-4-26b-a4b-it:free",
            "google/gemma-4-31b-it:free",
            "moonshotai/kimi-k2.5",
            "moonshotai/kimi-k2.6",
            "nvidia/nemotron-3-super-120b-a12b:free",
            "openrouter/owl-alpha",
            "qwen/qwen3-235b-a22b-2507",
            "qwen/qwen3.5-flash-02-23",
            "qwen/qwen3.6-plus",
            "x-ai/grok-4.1-fast",
            "x-ai/grok-4.3",
        ]
    )

    /// JSON wire shape. Every field optional — a partial override file
    /// (e.g. `{"openrouter": [...]}`) leaves the other providers' lists
    /// untouched. `_schema` / `_doc` keys in the JSON are ignored
    /// (Codable picks up the matching property names only).
    private struct OverrideLists: Decodable {
        var openai: [String]?
        var anthropic: [String]?
        var openrouter: [String]?
    }

    /// Layered loader (user override → bundled → empty payload). The
    /// payload itself is `OverrideLists` (all-optional fields); the
    /// merge step below substitutes `defaultLists` for any missing
    /// per-provider key, giving partial-override semantics.
    private static let loader = LayeredJSONConfig<OverrideLists>(
        resourceName: "CloudModels",
        userFilename: "cloud-models.json",
        bundle: .module,
        defaultValue: OverrideLists(openai: nil, anthropic: nil, openrouter: nil)
    )

    private static func effectiveLists() -> ResolvedLists {
        mergedWithDefaults(loader.resolve())
    }

    /// User overrides are merged per-key against the hardcoded defaults
    /// rather than wholesale-replacing them. A user file like
    /// `{"openrouter": ["my/private-id"]}` overrides only OpenRouter's
    /// list; OpenAI and Anthropic still pull from the defaults. Prevents
    /// the user from accidentally erasing all OpenAI suggestions because
    /// they only wanted to customize OpenRouter.
    ///
    /// Empty arrays in the user file (`{"openai": []}`) ARE respected —
    /// the user is explicitly opting out of OpenAI suggestions.
    private static func mergedWithDefaults(_ override: OverrideLists) -> ResolvedLists {
        ResolvedLists(
            openai: override.openai ?? defaultLists.openai,
            anthropic: override.anthropic ?? defaultLists.anthropic,
            openrouter: override.openrouter ?? defaultLists.openrouter
        )
    }

}

/// URL acceptability check for `.openaiCompatible` endpoints. Allows
/// `https://` everywhere and `http://` only for loopback hosts so local
/// runtimes (Ollama default `http://localhost:11434/v1`, LM Studio's
/// equivalent) work without forcing self-signed-cert gymnastics. Any
/// other `http://` URL is rejected — sending an API key over plaintext
/// to a non-loopback host would be a real footgun.
public enum CloudEndpointPolicy {
    public static func isAcceptable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "https":
            return url.host?.isEmpty == false
        case "http":
            guard let host = url.host?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default:
            return false
        }
    }
}
