import Foundation
import InferCore

/// The synthetic default agent: exactly what Infer ships today (no tools,
/// no loop, system prompt and decoding params from `InferSettings`). Per
/// `docs/dev/agents.md`, this is what the "Default" row in the picker
/// corresponds to. Historical transcripts that pre-date agent attribution
/// are displayed as if produced by this agent.
///
/// Intentionally synthetic rather than materialised as a JSON persona:
/// it tracks the user's live `InferSettings` edits turn-by-turn instead
/// of pinning to a file.
public struct DefaultAgent: Agent {
    public static let id: AgentID = "infer.default"

    public let settings: InferSettings

    public init(settings: InferSettings = .defaults) {
        self.settings = settings
    }

    public var id: AgentID { Self.id }

    public var metadata: AgentMetadata {
        AgentMetadata(
            name: "Default",
            description: "Infer's built-in assistant with user-configured settings.",
            author: "first-party"
        )
    }

    public var requirements: AgentRequirements {
        AgentRequirements(backend: .any)
    }

    public func decodingParams(for context: AgentContext) -> DecodingParams {
        DecodingParams(from: settings)
    }

    public func systemPrompt(for context: AgentContext) async throws -> String {
        settings.systemPrompt
    }
}
