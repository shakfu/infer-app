import SwiftUI
import InferAgents

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, system }

    /// What this row represents in the transcript. `.message` is the usual
    /// user / assistant / system turn. `.agentDivider` is a UI-only marker
    /// inserted when the active agent changes mid-conversation — it has
    /// no role in backend prompts and is not persisted to the vault.
    enum Kind: Equatable {
        case message
        case agentDivider(agentName: String)
    }

    let id = UUID()
    let role: Role
    var kind: Kind = .message
    var text: String
    /// Optional image attached to this user turn. Ephemeral — not persisted
    /// to the vault or the `.md` transcript. Live session only.
    var imageURL: URL? = nil
    /// Per-turn agent trace. Nil on user messages, on pre-agent assistant
    /// history, and on assistant messages produced by the default no-tool
    /// path. Populated once the loop (PR 2+) emits tool calls.
    var steps: StepTrace? = nil
    /// Id of the agent that produced this message. Nil for user turns and
    /// for historical assistant turns that pre-date agent attribution.
    var agentId: AgentID? = nil
    /// Display name of the agent that produced this message at the time
    /// the message was appended. Populated only for non-Default agents
    /// (for Default the role column just says "assistant"). Snapshotted
    /// here rather than resolved on render so the transcript stays
    /// readable if the user later edits or deletes the persona.
    var agentName: String? = nil
}

enum Backend: String, CaseIterable, Identifiable {
    case llama
    case mlx
    var id: String { rawValue }
    var label: String {
        switch self {
        case .llama: return "llama.cpp"
        case .mlx: return "MLX"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}
