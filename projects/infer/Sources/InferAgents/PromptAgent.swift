import Foundation
import InferCore

/// JSON-backed persona. Reads a JSON file on disk and conforms to `Agent`
/// with static implementations of every hook. This is the "persona pack"
/// case. Users and plugins can author these without touching Swift.
///
/// The schema is itself a versioned, user-facing API. The file's
/// `schemaVersion` drives forward-compatible parsing:
/// - Unknown fields in a known major version are ignored (`Codable`'s
///   default behaviour plus our explicit `decodeIfPresent` path for
///   optional fields).
/// - An unknown `schemaVersion` rejects the file with
///   `AgentError.unsupportedSchemaVersion` so the Agents tab can show the
///   user a "file requires a newer Infer" reason row instead of silently
///   loading a malformed agent.
public struct PromptAgent: Agent, Codable, Equatable {
    /// Current persona schema major version. Breaking renames bump this
    /// and keep the prior major loadable for one release.
    public static let currentSchemaVersion = 1
    public static let supportedSchemaVersions: Set<Int> = [1]

    public let schemaVersion: Int
    public let id: AgentID
    public let metadata: AgentMetadata
    public let requirements: AgentRequirements

    /// Stored default decoding params. Exposed to the protocol via
    /// `decodingParams(for:)`; separate property name avoids the method
    /// shadowing that would otherwise conflict.
    public let defaultDecodingParams: DecodingParams

    /// Stored system prompt text. Exposed via `systemPrompt(for:)`.
    public let promptText: String

    public init(
        id: AgentID,
        metadata: AgentMetadata,
        requirements: AgentRequirements = AgentRequirements(),
        decodingParams: DecodingParams = DecodingParams(from: .defaults),
        systemPrompt: String
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.metadata = metadata
        self.requirements = requirements
        self.defaultDecodingParams = decodingParams
        self.promptText = systemPrompt
    }

    public func decodingParams(for context: AgentContext) -> DecodingParams {
        defaultDecodingParams
    }

    public func systemPrompt(for context: AgentContext) async throws -> String {
        promptText
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case metadata
        case requirements
        case decodingParams
        case systemPrompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard Self.supportedSchemaVersions.contains(version) else {
            throw AgentError.unsupportedSchemaVersion(version)
        }
        let id = try c.decode(AgentID.self, forKey: .id)
        guard !id.isEmpty else {
            throw AgentError.invalidPersona("id is empty")
        }
        let metadata = try c.decode(AgentMetadata.self, forKey: .metadata)
        guard !metadata.name.isEmpty else {
            throw AgentError.invalidPersona("metadata.name is empty")
        }
        let prompt = try c.decode(String.self, forKey: .systemPrompt)

        self.schemaVersion = version
        self.id = id
        self.metadata = metadata
        self.requirements = (try? c.decode(AgentRequirements.self, forKey: .requirements))
            ?? AgentRequirements()
        self.defaultDecodingParams = (try? c.decode(DecodingParams.self, forKey: .decodingParams))
            ?? DecodingParams(from: .defaults)
        self.promptText = prompt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(requirements, forKey: .requirements)
        try c.encode(defaultDecodingParams, forKey: .decodingParams)
        try c.encode(promptText, forKey: .systemPrompt)
    }
}
