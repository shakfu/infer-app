import Foundation

/// UserDefaults keys used by the app. Centralized here so tests and call
/// sites share a single source of truth.
public enum PersistKey {
    public static let backend = "infer.lastBackend"
    public static let systemPrompt = "infer.systemPrompt"
    public static let temperature = "infer.temperature"
    public static let topP = "infer.topP"
    public static let maxTokens = "infer.maxTokens"
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
}

public struct InferSettings: Equatable, Sendable {
    public var systemPrompt: String
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int
    /// Optional sampling seed. `nil` means use a random seed (non-deterministic
    /// output). When set, identical prompt + params + seed produces identical
    /// output on a given backend. Stored as a string in UserDefaults since
    /// `UserDefaults` has no native `UInt64` path.
    public var seed: UInt64?

    public init(
        systemPrompt: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int,
        seed: UInt64? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.seed = seed
    }

    public static let defaults = InferSettings(
        systemPrompt: "",
        temperature: 0.8,
        topP: 0.95,
        maxTokens: 512,
        seed: nil
    )

    public static func load(from defaults: UserDefaults = .standard) -> InferSettings {
        let seedString = defaults.string(forKey: PersistKey.seed)
        let seed: UInt64? = seedString.flatMap { UInt64($0) }
        return InferSettings(
            systemPrompt: defaults.string(forKey: PersistKey.systemPrompt) ?? "",
            temperature: defaults.object(forKey: PersistKey.temperature) as? Double ?? Self.defaults.temperature,
            topP: defaults.object(forKey: PersistKey.topP) as? Double ?? Self.defaults.topP,
            maxTokens: defaults.object(forKey: PersistKey.maxTokens) as? Int ?? Self.defaults.maxTokens,
            seed: seed
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(systemPrompt, forKey: PersistKey.systemPrompt)
        defaults.set(temperature, forKey: PersistKey.temperature)
        defaults.set(topP, forKey: PersistKey.topP)
        defaults.set(maxTokens, forKey: PersistKey.maxTokens)
        if let seed {
            defaults.set(String(seed), forKey: PersistKey.seed)
        } else {
            defaults.removeObject(forKey: PersistKey.seed)
        }
    }
}
