import Foundation

/// One row in a `TranscriptStore`. Lighter than the app-side
/// `ChatMessage` (no SwiftUI / `StepTrace` / persona attribution), and
/// `Sendable` so it can flow across actor boundaries without
/// `@unchecked` workarounds. The app's view model can adapt these to
/// `ChatMessage` when (and if) it adopts the store; tests can use
/// `TranscriptEntry` directly.
public struct TranscriptEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var role: ChatTurn.Role
    public var text: String
    public var imageURL: URL?

    public init(id: UUID = UUID(), role: ChatTurn.Role, text: String, imageURL: URL? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.imageURL = imageURL
    }
}

/// Pure value-typed transcript model + the operations the chat-VM
/// performs on its `messages: [ChatMessage]` array. Extracted so the
/// edit-and-resend, regenerate, and stream-append flows can be exercised
/// in isolation — these are the operations that historically race with
/// generation in the app target (`Generation.swift` mutates `messages`
/// from the streaming task while the user can simultaneously click
/// "edit" or "regenerate").
///
/// All mutations are explicit; the store does not manage timers, tasks,
/// or runner state. Tests that combine transcript ops with a
/// `MockChatRunner` model the real coupling without dragging in
/// `ChatViewModel`'s 20+ concrete collaborators.
public struct TranscriptStore: Sendable, Equatable {
    public private(set) var entries: [TranscriptEntry] = []

    public init(entries: [TranscriptEntry] = []) {
        self.entries = entries
    }

    // MARK: - Append

    @discardableResult
    public mutating func appendUser(_ text: String, imageURL: URL? = nil) -> UUID {
        let entry = TranscriptEntry(role: .user, text: text, imageURL: imageURL)
        entries.append(entry)
        return entry.id
    }

    /// Begin a new assistant turn with empty text. Subsequent
    /// `appendChunk(_:to:)` calls populate it as the stream arrives.
    @discardableResult
    public mutating func beginAssistant() -> UUID {
        let entry = TranscriptEntry(role: .assistant, text: "")
        entries.append(entry)
        return entry.id
    }

    /// Append a chunk of streamed text to the entry with the given id.
    /// No-op if the id is not in the store (e.g. the row was deleted by
    /// a concurrent edit while the stream was still draining — this is
    /// the F-8 race window the chat-VM has today). Tests can assert
    /// the no-op behaviour explicitly.
    public mutating func appendChunk(_ chunk: String, to id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text.append(chunk)
    }

    /// Replace a row's text wholesale (used by transcript-load and by
    /// `<think>`-block stripping at end-of-turn).
    public mutating func setText(_ text: String, for id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text = text
    }

    public mutating func reset() {
        entries.removeAll()
    }

    // MARK: - Edit / regenerate

    /// Truncate the transcript so the named user turn becomes the new
    /// last entry, with its text replaced. Returns the entries that
    /// were dropped (in original order) so the caller can decide
    /// whether to surface them (e.g. preserve a partial draft) or
    /// discard. Returns nil — and does not mutate — if `id` is not in
    /// the store, or is not a user turn.
    @discardableResult
    public mutating func editAndResend(messageId id: UUID, newText: String) -> [TranscriptEntry]? {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        guard entries[idx].role == .user else { return nil }
        // Preserve the original user row's image attachment on rewrite —
        // image attachments are turn-scoped on the chat-VM side, so an
        // edit-and-resend should keep the picture the user attached to
        // the original turn. Capture before we truncate.
        let originalImage = entries[idx].imageURL
        let dropped = Array(entries[(idx + 1)...])
        entries.removeSubrange(idx...)
        let rewritten = TranscriptEntry(role: .user, text: newText, imageURL: originalImage)
        entries.append(rewritten)
        return dropped
    }

    /// Drop the trailing assistant turn so the prior user turn can be
    /// re-sent. Returns the user turn's text on success; nil — and no
    /// mutation — if the trailing entry is not an assistant turn that
    /// follows a user turn.
    public mutating func regenerate() -> String? {
        guard entries.count >= 2,
              entries.last?.role == .assistant,
              entries[entries.count - 2].role == .user
        else { return nil }
        entries.removeLast()
        return entries.last?.text
    }

    // MARK: - Snapshots

    /// `ChatTurn` snapshot suitable for `ChatRunner.setHistory`. The
    /// chat-VM filters system turns out before calling `setHistory`
    /// because each runner injects the current `settings.systemPrompt`
    /// itself; this helper does the same.
    public func turnsForHistory() -> [ChatTurn] {
        entries
            .filter { $0.role != .system }
            .map { entry in
                ChatTurn(
                    role: entry.role,
                    content: entry.text,
                    imageURLs: entry.imageURL.map { [$0] } ?? []
                )
            }
    }
}
