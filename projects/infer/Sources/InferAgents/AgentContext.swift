import Foundation

public struct RunnerHandle: Sendable, Equatable {
    public let backend: BackendPreference
    public let templateFamily: TemplateFamily?
    public let maxContext: Int
    public let currentTokenCount: Int

    public init(
        backend: BackendPreference,
        templateFamily: TemplateFamily?,
        maxContext: Int,
        currentTokenCount: Int
    ) {
        self.backend = backend
        self.templateFamily = templateFamily
        self.maxContext = maxContext
        self.currentTokenCount = currentTokenCount
    }
}

public struct TranscriptMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ToolSpec: Codable, Equatable, Sendable {
    public var name: ToolName
    public var description: String

    public init(name: ToolName, description: String = "") {
        self.name = name
        self.description = description
    }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public var name: ToolName
    /// Arguments as a raw JSON string. Kept as text rather than a decoded
    /// type so the transcript can survive schema evolution without the
    /// agent layer needing to know each tool's schema.
    public var arguments: String

    public init(name: ToolName, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Codable, Equatable, Sendable {
    public var output: String
    public var error: String?

    public init(output: String, error: String? = nil) {
        self.output = output
        self.error = error
    }
}

/// The set of tools the plugin layer has made available for a given turn,
/// already filtered by per-plugin consent. Agents further restrict this set
/// via `toolsAllow`/`toolsDeny` in their requirements (default hook in
/// `Agent.toolsAvailable`).
public struct ToolCatalog: Sendable, Equatable {
    public let tools: [ToolSpec]

    public init(tools: [ToolSpec] = []) {
        self.tools = tools
    }

    public static let empty = ToolCatalog()
}

/// Read-only handle passed to every `Agent` hook.
///
/// Contains the minimal information an agent needs to shape a turn: a
/// description of the active runner (not the runner actor itself), the
/// filtered tool catalog, a snapshot of the transcript so far, and the
/// current step counter.
///
/// Explicitly **not** in `AgentContext`: the runner actor reference, the
/// `ChatViewModel`, `InferSettings` (agents override via `decodingParams`,
/// not by reading user prefs), the `PluginHost`, or any mutable UI state.
/// The absence list is load-bearing — once a conformance depends on
/// something here, the shape is frozen, so this surface stays thin.
public struct AgentContext: Sendable {
    public let runner: RunnerHandle
    public let tools: ToolCatalog
    public let transcript: [TranscriptMessage]
    public let stepCount: Int

    public init(
        runner: RunnerHandle,
        tools: ToolCatalog = .empty,
        transcript: [TranscriptMessage] = [],
        stepCount: Int = 0
    ) {
        self.runner = runner
        self.tools = tools
        self.transcript = transcript
        self.stepCount = stepCount
    }
}

public struct AgentTurn: Sendable, Equatable {
    public let userText: String

    public init(userText: String) {
        self.userText = userText
    }
}
