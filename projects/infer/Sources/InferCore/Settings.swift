import Foundation

/// UserDefaults keys used by the app. Centralized here so tests and call
/// sites share a single source of truth.
public enum PersistKey {
    public static let backend = "infer.lastBackend"
    public static let systemPrompt = "infer.systemPrompt"
    public static let temperature = "infer.temperature"
    public static let topP = "infer.topP"
    public static let maxTokens = "infer.maxTokens"
    public static let sidebarOpen = "infer.sidebarOpen"
    public static let appearance = "infer.appearance"
    public static let ttsEnabled = "infer.ttsEnabled"
    public static let ttsVoiceId = "infer.ttsVoiceId"
    public static let voiceSendPhrase = "infer.voiceSendPhrase"
    public static let ggufDirectory = "infer.ggufDirectory"
}

public struct InferSettings: Equatable, Sendable {
    public var systemPrompt: String
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int

    public init(systemPrompt: String, temperature: Double, topP: Double, maxTokens: Int) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    public static let defaults = InferSettings(
        systemPrompt: "",
        temperature: 0.8,
        topP: 0.95,
        maxTokens: 512
    )

    public static func load(from defaults: UserDefaults = .standard) -> InferSettings {
        InferSettings(
            systemPrompt: defaults.string(forKey: PersistKey.systemPrompt) ?? "",
            temperature: defaults.object(forKey: PersistKey.temperature) as? Double ?? Self.defaults.temperature,
            topP: defaults.object(forKey: PersistKey.topP) as? Double ?? Self.defaults.topP,
            maxTokens: defaults.object(forKey: PersistKey.maxTokens) as? Int ?? Self.defaults.maxTokens
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(systemPrompt, forKey: PersistKey.systemPrompt)
        defaults.set(temperature, forKey: PersistKey.temperature)
        defaults.set(topP, forKey: PersistKey.topP)
        defaults.set(maxTokens, forKey: PersistKey.maxTokens)
    }
}
