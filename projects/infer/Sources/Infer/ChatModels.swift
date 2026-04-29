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
    /// Unicode-safe flattened label for the role column ("code-helper").
    /// Snapshotted alongside `agentName` so renaming or deleting the
    /// persona does not retroactively change historical rows.
    var agentLabel: String? = nil
    /// RAG context injected into this reply's prompt. Populated by
    /// the query pipeline before generation; rendered below the
    /// message body as a collapsed "Sources" disclosure. Ephemeral —
    /// only the prose lands in the vault; reloading a conversation
    /// from history shows messages without their retrieval provenance.
    var retrievedChunks: [RetrievedChunkRef]? = nil
    /// Captured `<think>…</think>` content for reasoning models
    /// (Qwen-3, DeepSeek-R1, etc.). Streamed in real time alongside
    /// the visible body, displayed in a collapsible "thinking"
    /// disclosure on the assistant message. Nil when the model
    /// emitted no thinking content. Ephemeral — same vault posture
    /// as `retrievedChunks`.
    var thinkingText: String? = nil
    /// True while the runner is currently inside a `<think>` block.
    /// Drives the live "thinking…" indicator state in the disclosure
    /// header — switches off when the model emits `</think>` and
    /// the visible answer starts arriving.
    var isThinking: Bool = false
    /// Most recent `ToolEvent.log` line from a streaming tool whose
    /// invocation is currently in flight. Cleared when the tool
    /// resolves. Surfaces in `StepTraceDisclosure.pendingRow` so the
    /// user sees what a long-running tool (Quarto render, big http
    /// fetch) is doing instead of a silent spinner. Ephemeral —
    /// not persisted.
    var latestToolProgress: String? = nil
}

enum Backend: String, CaseIterable, Identifiable {
    case llama
    case mlx
    case cloud
    var id: String { rawValue }
    var label: String {
        switch self {
        case .llama: return "llama.cpp"
        case .mlx: return "MLX"
        case .cloud: return "Cloud"
        }
    }
}

/// One row in the Stable Diffusion gallery. Ties an on-disk PNG to its
/// sidecar metadata; `Identifiable` so SwiftUI's `ForEach` can diff
/// without a manual `id:` keypath.
struct SDGalleryEntry: Identifiable, Equatable {
    let imageURL: URL
    let metadata: GeneratedImageMetadata
    var id: URL { imageURL }
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
