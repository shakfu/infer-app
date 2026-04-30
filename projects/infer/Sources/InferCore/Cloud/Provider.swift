import Foundation

/// Identity of a cloud chat backend. Three flavors:
///
/// - `.openai` — canonical OpenAI at `api.openai.com`. Bearer-token auth.
/// - `.anthropic` — canonical Anthropic at `api.anthropic.com`. `x-api-key` auth.
/// - `.openaiCompatible` — user-supplied base URL plus a display name. Reuses
///   the OpenAI wire format (`/v1/chat/completions` + SSE), so any provider
///   that speaks it (Ollama, LM Studio, Groq, Together, OpenRouter, …) drops
///   in by overriding the URL. The `name` is what the user sees in the
///   backend picker; it also feeds the keychain account string so multiple
///   compat endpoints don't share credentials.
public enum CloudProvider: Sendable, Hashable {
    case openai
    case anthropic
    case openaiCompatible(name: String, baseURL: URL)

    /// Human-readable label for UI surfaces.
    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openaiCompatible(let name, _): return name
        }
    }

    /// Account string used by `APIKeyStore` so each provider — including
    /// each compat endpoint by name — gets its own keychain item.
    public var keychainAccount: String {
        switch self {
        case .openai: return "openai"
        case .anthropic: return "anthropic"
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
    case openaiCompatible

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openaiCompatible: return "OpenAI-compatible"
        }
    }
}

extension CloudProvider {
    public var kind: CloudProviderKind {
        switch self {
        case .openai: return .openai
        case .anthropic: return .anthropic
        case .openaiCompatible: return .openaiCompatible
        }
    }
}

/// Curated list of model ids surfaced as suggestions in the model picker.
/// Free-text input is still accepted — this is just the dropdown half of
/// the hybrid UX. Model ids change as providers ship new SKUs; keep this
/// list updated when adding support, and treat staleness as a docs bug
/// rather than a runtime one (the wire layer accepts any string).
public enum CloudRecommendedModels {
    /// As of 2026-04. OpenAI's id scheme has shifted twice in two years;
    /// confirm against `api.openai.com/v1/models` if the user reports a
    /// 404 from a listed entry. `gpt-5.4-nano` is the default — listed
    /// first so the picker surfaces it as the first suggestion.
    public static let openai: [String] = [
        "gpt-5.4-nano",
        "gpt-5.4-mini",
        "gpt-5.4",
        "gpt-5.4-pro",
        "gpt-5.5",
        "gpt-5.5-pro",
    ]
    /// As of 2026-04. Undated official aliases — Anthropic accepts both
    /// the alias and the dated snapshot id; the alias auto-tracks the
    /// latest snapshot of that minor version.
    public static let anthropic: [String] = [
        "claude-opus-4-7",
        "claude-sonnet-4-6",
        "claude-haiku-4-5",
    ]

    public static func suggestions(for provider: CloudProvider) -> [String] {
        switch provider {
        case .openai: return openai
        case .anthropic: return anthropic
        case .openaiCompatible: return []
        }
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
