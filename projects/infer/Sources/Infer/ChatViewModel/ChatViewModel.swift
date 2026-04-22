import Foundation
import InferCore

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var input: String = ""
    var backend: Backend = .llama
    var modelLoaded: Bool = false
    var modelStatus: String = "No model loaded"
    var isLoadingModel = false
    var isGenerating = false
    var errorMessage: String? = nil
    /// User-entered model input. For MLX this is an HF repo id (empty =>
    /// registry default). For llama this is an absolute path, a bare filename
    /// resolved against the configured GGUF directory, or an http(s):// URL
    /// to download before loading.
    var modelInput: String = ""
    /// Canonical id of the currently-loaded model; populated on successful load.
    /// For llama this is the absolute .gguf path; for MLX the HF id (or the
    /// registry default's resolved name).
    var currentModelId: String? = nil
    /// Directory used to store .gguf files downloaded via URL and to resolve
    /// bare filenames from the text field. Empty => ModelStore default.
    var ggufDirectory: String = UserDefaults.standard.string(forKey: PersistKey.ggufDirectory) ?? "" {
        didSet { UserDefaults.standard.set(ggufDirectory, forKey: PersistKey.ggufDirectory) }
    }
    /// Previously-loaded models from the vault, filtered to those whose local
    /// artifact still exists. Refreshed after each successful load and on init.
    var availableModels: [VaultModelEntry] = []
    var settings: InferSettings = InferSettings.load()
    var downloadProgress: Double? = nil
    var tokenUsage: TokenUsage? = nil
    /// Number of stream pieces received for the current or most-recent
    /// generation. For both backends, stream pieces correspond 1:1 with
    /// sampled tokens in the common case (they may merge for multi-byte UTF-8
    /// fragments — close enough for a user-facing tok/s readout).
    var generationTokenCount: Int = 0
    var generationStart: Date? = nil
    var generationEnd: Date? = nil

    /// Tokens + tok/s for the current (if generating) or most-recent
    /// generation. Nil when no generation has happened in this session.
    var generationStats: (tokens: Int, tps: Double)? {
        guard let start = generationStart, generationTokenCount > 0 else { return nil }
        let end = generationEnd ?? Date()
        let elapsed = end.timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        return (generationTokenCount, Double(generationTokenCount) / elapsed)
    }
    let llama = LlamaRunner()
    let mlx = MLXRunner()
    let ggufDownloader = GGUFDownloader()
    let speechRecognizer = SpeechRecognizer()
    let speechSynthesizer = SpeechSynthesizer()
    let whisperModels = WhisperModelManager()
    let audioRecorder = AudioFileRecorder()

    /// True while a dropped audio file is being transcribed. Mutually
    /// exclusive for simplicity — the second drop is ignored with a banner.
    var isTranscribingFile: Bool = false
    var transcriptionStatus: String? = nil

    /// Image queued to be sent with the next message. Ephemeral: cleared on
    /// send, on reset, or when the user clicks the × on the preview chip.
    var pendingImageURL: URL? = nil

    let vault = VaultStore.shared

    /// Row id of the in-progress vault conversation, or nil if no turns have
    /// been recorded yet (next `send()` will create a new row).
    var currentConversationId: Int64? = nil

    // Vault search UI state.
    var vaultQuery: String = ""
    var vaultResults: [VaultSearchHit] = []
    var vaultRecents: [VaultConversationSummary] = []
    var vaultSearchTask: Task<Void, Never>? = nil

    var ttsEnabled: Bool = UserDefaults.standard.bool(forKey: PersistKey.ttsEnabled) {
        didSet { UserDefaults.standard.set(ttsEnabled, forKey: PersistKey.ttsEnabled) }
    }
    var ttsVoiceId: String = UserDefaults.standard.string(forKey: PersistKey.ttsVoiceId) ?? "" {
        didSet { UserDefaults.standard.set(ttsVoiceId, forKey: PersistKey.ttsVoiceId) }
    }
    /// Trailing phrase that, when detected at the end of dictated text,
    /// strips itself and submits the message. Empty disables voice send.
    var voiceSendPhrase: String = UserDefaults.standard.string(forKey: PersistKey.voiceSendPhrase) ?? "send it" {
        didSet { UserDefaults.standard.set(voiceSendPhrase, forKey: PersistKey.voiceSendPhrase) }
    }

    var generationTask: Task<Void, Never>? = nil
    var loadTask: Task<Void, Never>? = nil

    /// Clear the transcript, cancel any in-flight generation, and reset both
    /// backends' conversation state. Model stays loaded; settings untouched.
    func reset() {
        stop()
        messages.removeAll()
        generationTokenCount = 0
        generationStart = nil
        generationEnd = nil
        currentConversationId = nil
        pendingImageURL = nil
        let b = self.backend
        Task {
            switch b {
            case .llama: await self.llama.resetConversation()
            case .mlx: await self.mlx.resetConversation()
            }
            await MainActor.run { self.refreshTokenUsage() }
        }
    }

    /// Stable identifier string used as the vault's `model_id` column.
    func vaultModelId() -> String {
        currentModelId ?? ""
    }
}
