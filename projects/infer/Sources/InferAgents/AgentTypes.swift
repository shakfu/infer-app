import Foundation
import InferCore

/// Stable, URL-safe identifier for an agent. Used as the registry key,
/// for transcript attribution, and for consent scoping.
public typealias AgentID = String

/// Tool name as exposed by the tool registry. A plain string today; could
/// become a newtype later without source-breaking call sites that construct
/// it from literals.
public typealias ToolName = String

public struct AgentMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var icon: String?
    public var author: String?

    public init(
        name: String,
        description: String = "",
        icon: String? = nil,
        author: String? = nil
    ) {
        self.name = name
        self.description = description
        self.icon = icon
        self.author = author
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, icon, author
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.author = try c.decodeIfPresent(String.self, forKey: .author)
    }
}

public enum TemplateFamily: String, Codable, Sendable, CaseIterable {
    case llama3
    case qwen
    case hermes
    case openai
}

public enum BackendPreference: String, Codable, Sendable, CaseIterable {
    case llama
    case mlx
    case any
}

public struct AgentRequirements: Codable, Equatable, Sendable {
    public var backend: BackendPreference
    public var templateFamily: TemplateFamily?
    public var minContext: Int?
    public var toolsAllow: [ToolName]
    public var toolsDeny: [ToolName]
    public var autoApprove: [ToolName]

    public init(
        backend: BackendPreference = .any,
        templateFamily: TemplateFamily? = nil,
        minContext: Int? = nil,
        toolsAllow: [ToolName] = [],
        toolsDeny: [ToolName] = [],
        autoApprove: [ToolName] = []
    ) {
        self.backend = backend
        self.templateFamily = templateFamily
        self.minContext = minContext
        self.toolsAllow = toolsAllow
        self.toolsDeny = toolsDeny
        self.autoApprove = autoApprove
    }
}

public struct DecodingParams: Codable, Equatable, Sendable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int

    public init(temperature: Double, topP: Double, maxTokens: Int) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    public init(from settings: InferSettings) {
        self.temperature = settings.temperature
        self.topP = settings.topP
        self.maxTokens = settings.maxTokens
    }
}

public enum LoopDecision: Sendable, Equatable {
    case `continue`
    case stop(reason: String)
    case stopAndSummarise
}

public enum AgentError: Error, Sendable, Equatable {
    /// Thrown by the default `Agent.run` implementation. PR 1 ships the
    /// substrate without a loop; conformances that want to produce a
    /// `StepTrace` from a user turn must wait for PR 2's `AgentSession`
    /// or override `run` directly.
    case loopNotAvailable
    /// JSON parse or validation failure. Message is user-facing (surfaced
    /// in the Agents tab as the reason a persona failed to load).
    case invalidPersona(String)
    /// The persona file declared a `schemaVersion` this build doesn't know
    /// how to read. See `PromptAgent.supportedSchemaVersions`.
    case unsupportedSchemaVersion(Int)
}

public enum AgentSource: Sendable, Equatable {
    case user
    case plugin
    case firstParty

    /// Higher wins on id collision. See `AgentRegistry.register`.
    public var precedence: Int {
        switch self {
        case .user: return 3
        case .plugin: return 2
        case .firstParty: return 1
        }
    }
}
