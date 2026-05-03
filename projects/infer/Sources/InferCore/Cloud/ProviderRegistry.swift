import Foundation

/// One entry in the cloud-provider picker. Combines fixed first-party
/// providers (OpenAI / Anthropic / OpenRouter / a "Custom…" escape hatch)
/// with dynamic entries loaded from `cloud-providers.json` — each
/// preset surfaces as its own picker row with a stable id.
public struct CloudProviderChoice: Sendable, Identifiable, Hashable {
    /// Stable id used for `Picker` `tag(...)` and persisted in
    /// `UserDefaults`. Static entries use their `CloudProviderKind`
    /// rawValue (`"openai"`, `"anthropic"`, `"openrouter"`, the
    /// custom-compat entry uses `"openaiCompatible"`); presets use
    /// `"compat:<normalized-name>"`. Reserved prefix `compat:` keeps
    /// presets from colliding with future kind ids.
    public let id: String
    public let label: String
    public let kind: CloudProviderKind
    /// Non-nil for preset entries from the JSON file. Nil for the four
    /// fixed entries (the custom-compat one uses the user-typed
    /// name/URL fields instead).
    public let preset: CompatPreset?

    public struct CompatPreset: Sendable, Hashable, Decodable {
        public let name: String
        public let baseURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case baseURL = "baseURL"
            case baseURLAlt = "base_url"
        }

        public init(name: String, baseURL: URL) {
            self.name = name
            self.baseURL = baseURL
        }

        // Accept both `baseURL` and `base_url` so users editing the
        // JSON by hand don't have to remember which casing wins.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            if let s = try c.decodeIfPresent(String.self, forKey: .baseURL),
               let u = URL(string: s) {
                self.baseURL = u
            } else if let s = try c.decodeIfPresent(String.self, forKey: .baseURLAlt),
                      let u = URL(string: s) {
                self.baseURL = u
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .baseURL,
                    in: c,
                    debugDescription: "missing or invalid baseURL / base_url"
                )
            }
        }
    }
}

/// Combined static + JSON-loaded list of cloud-provider picker rows.
/// Static entries are always present and always first; JSON presets
/// follow; the "Custom…" escape hatch is always last so the most
/// flexible option doesn't crowd out the curated choices visually.
///
/// Layered load (mirrors `CloudRecommendedModels`):
///   1. user override at `~/Library/Application Support/Infer/cloud-providers.json`
///   2. bundled `Resources/CloudProviders.json`
///   3. empty list (no presets ship by default)
///
/// User override replaces the bundled list wholesale — entries are a
/// list rather than a per-provider dict, so per-key merge doesn't
/// apply cleanly. To extend without losing built-ins, the user copies
/// the bundled list into their override file and adds entries.
public enum CloudProviderRegistry {
    /// Stable static ids — also valid `CloudProviderKind` rawValues
    /// for the kinds that don't carry a name+URL payload.
    public static let openaiID = "openai"
    public static let anthropicID = "anthropic"
    public static let openrouterID = "openrouter"
    /// Free-form custom OpenAI-compatible entry. The user types the
    /// name and URL in the existing fields (see `CloudSidebar`) and
    /// the runtime constructs `.openaiCompatible(name:baseURL:)` from
    /// those values rather than from a preset.
    public static let customCompatID = "openaiCompatible"

    /// All picker entries, in display order: static first, presets
    /// next, custom-compat last. Reads through the layered loader on
    /// every call (cached after the first), so a relaunch picks up
    /// edits to either the bundled JSON or the user override.
    public static func all() -> [CloudProviderChoice] {
        var out: [CloudProviderChoice] = [
            .init(id: openaiID, label: "OpenAI", kind: .openai, preset: nil),
            .init(id: anthropicID, label: "Anthropic", kind: .anthropic, preset: nil),
            .init(id: openrouterID, label: "OpenRouter", kind: .openrouter, preset: nil),
        ]
        for preset in effectivePresets() where CloudEndpointPolicy.isAcceptable(preset.baseURL) {
            out.append(.init(
                id: presetID(forName: preset.name),
                label: preset.name,
                kind: .openaiCompatible,
                preset: preset
            ))
        }
        out.append(.init(
            id: customCompatID,
            label: "OpenAI-compatible (custom)…",
            kind: .openaiCompatible,
            preset: nil
        ))
        return out
    }

    /// Look up a choice by id. Returns the custom-compat entry if the
    /// id is missing — handles the case where a user removes a preset
    /// from their JSON while it's still the persisted selection.
    public static func find(id: String) -> CloudProviderChoice {
        let entries = all()
        if let hit = entries.first(where: { $0.id == id }) { return hit }
        return entries.first(where: { $0.id == customCompatID })!
    }

    /// `compat:<slug>` form. Keep in sync with `CloudProvider.keychainAccount`'s
    /// normalization so a preset's choice id and its keychain slot
    /// derive from the same normalized name.
    public static func presetID(forName name: String) -> String {
        "compat:" + Self.slug(name)
    }

    /// Lowercases and replaces non-`[a-z0-9._-]` runs with `-`.
    /// Mirrors `CloudProvider.normalizeAccountSuffix` so the picker
    /// id and the keychain account stay coupled.
    private static func slug(_ s: String) -> String {
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

    // MARK: - Layered load

    private struct PresetsFile: Decodable {
        var providers: [CloudProviderChoice.CompatPreset]?
    }

    private static let loader = LayeredJSONConfig<PresetsFile>(
        resourceName: "CloudProviders",
        userFilename: "cloud-providers.json",
        bundle: .module,
        defaultValue: PresetsFile(providers: nil)
    )

    private static func effectivePresets() -> [CloudProviderChoice.CompatPreset] {
        loader.resolve().providers ?? []
    }
}
