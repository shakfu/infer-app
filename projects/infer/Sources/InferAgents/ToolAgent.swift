import Foundation
import InferCore

/// First-party agent that declares a fixed tool set at construction.
///
/// Stub in PR 1: there is no `ToolRegistry` yet, so `toolList` is only
/// ever empty in practice. The type exists now so the `AgentRegistry` can
/// be exercised with three conformance shapes (Default, Prompt, Tool) and
/// so call sites don't churn when PR 2 introduces real tools.
public struct ToolAgent: Agent {
    public let id: AgentID
    public let metadata: AgentMetadata
    public let requirements: AgentRequirements
    public let defaultDecodingParams: DecodingParams
    public let promptText: String
    public let toolList: [ToolSpec]

    public init(
        id: AgentID,
        metadata: AgentMetadata,
        requirements: AgentRequirements = AgentRequirements(),
        decodingParams: DecodingParams = DecodingParams(from: .defaults),
        systemPrompt: String,
        tools: [ToolSpec] = []
    ) {
        self.id = id
        self.metadata = metadata
        self.requirements = requirements
        self.defaultDecodingParams = decodingParams
        self.promptText = systemPrompt
        self.toolList = tools
    }

    public func decodingParams(for context: AgentContext) -> DecodingParams {
        defaultDecodingParams
    }

    public func systemPrompt(for context: AgentContext) async throws -> String {
        promptText
    }

    /// Override of the default: intersect the declared tool list with the
    /// catalog the host actually exposes, also honouring the usual
    /// allow/deny rules from `AgentRequirements`.
    public func toolsAvailable(for context: AgentContext) async throws -> [ToolSpec] {
        let declared = Set(toolList.map(\.name))
        let allow = Set(requirements.toolsAllow)
        let deny = Set(requirements.toolsDeny)
        return context.tools.tools.filter { spec in
            guard declared.contains(spec.name) else { return false }
            guard !deny.contains(spec.name) else { return false }
            return allow.isEmpty || allow.contains(spec.name)
        }
    }
}
