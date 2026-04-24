import Foundation
import InferAgents
import InferCore
import InferRAG

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
    /// State machine for agent selection. Owns the registry, the
    /// `activeAgentId`, the sorted `availableAgents` snapshot, and the
    /// cached `activeDecodingParams`. The VM is a thin adapter that
    /// translates the effects it returns into runner and transcript
    /// mutations (see `Agents.swift`). Extracted to `InferAgents` so the
    /// selection logic is unit-testable without the runner stack.
    let agentController = AgentController()
    /// Dedicated llama.cpp context configured for embedding inference.
    /// Loaded lazily on the first RAG ingest/query; stays resident
    /// after that. Independent of the chat `LlamaRunner`/`MLXRunner`.
    let embedder = EmbeddingRunner()
    /// Cross-encoder reranker (bge-reranker-v2-m3). Scores (query,
    /// chunk) pairs and is used by the RAG pipeline to reorder
    /// hybrid-search candidates when the user enables reranking on
    /// a workspace. Lazy-loads; stays resident after first use.
    let reranker = RerankerRunner()
    /// RAG vector store (sqlite-vec via SQLiteVec's bundled SQLite).
    /// One shared instance for the whole app; separate DB file from
    /// the main vault. Schema is bootstrapped lazily on first use.
    let vectorStore = VectorStore()
    /// Non-modal notification surface for background confirmations
    /// (duplicate success, non-fatal warnings). Overlaid on `ChatView`;
    /// any `@MainActor` code can call `toasts.show(_:)` to surface a
    /// short message without an alert dialog.
    let toasts = ToastCenter()
    /// Structured log sink. All code paths that previously wrote to
    /// stderr now also call `logs.log(...)`; stderr remains the
    /// fallback so developers running from a shell still see output.
    /// Surfaced in the Console sidebar tab.
    let logs = LogCenter()
    /// True while a background download of the embedding model is
    /// in flight. Observed by the workspace sheet to show progress
    /// and disable scan affordances.
    var embeddingModelDownloading: Bool = false
    /// Fractional progress of the embedding model download [0, 1].
    var embeddingModelDownloadProgress: Double = 0
    /// Same pair for the reranker model.
    var rerankerModelDownloading: Bool = false
    var rerankerModelDownloadProgress: Double = 0
    /// Live ingestion progress, non-nil while a scan is running.
    /// Observed by the workspace sheet's progress UI.
    var ingestProgress: IngestProgress? = nil
    /// Corpus stats for the workspace currently visible in the
    /// management sheet. Refreshed after `refreshCorpusStats`; nil
    /// if the sheet isn't open or no workspace is selected.
    var corpusStats: (workspaceId: Int64, sources: Int, chunks: Int)? = nil

    /// All workspaces in the vault. Refreshed on launch and after
    /// create/rename/delete. The Default workspace (created by the v4
    /// migration) is always present — this array is never empty on a
    /// healthy vault.
    var workspaces: [WorkspaceSummary] = []
    /// Id of the currently-active workspace. Persisted to UserDefaults.
    /// Every new conversation is created against this workspace; the
    /// RAG pipeline scopes its queries to this workspace's corpus.
    /// Nil at first launch before workspaces are loaded; set to the
    /// persisted value (or the Default workspace id) after bootstrap.
    var activeWorkspaceId: Int64? = nil
    /// Workspace currently open in the management sheet (nil = sheet
    /// dismissed). Presenting the sheet from the header switcher sets
    /// this to the currently-active workspace, which prefills fields.
    var workspaceInSheet: WorkspaceSummary? = nil
    /// True when the management sheet is presenting the create-new form
    /// rather than editing an existing workspace.
    var creatingWorkspace: Bool = false

    /// Listing currently displayed in the agent inspector sheet.
    /// Single source of truth so the sheet can be triggered from
    /// anywhere — library row click, app-level command (`Cmd+Shift+I`),
    /// or future plugin-driven openers — and always present on `ChatView`,
    /// which stays in the view hierarchy regardless of which sidebar
    /// tab is active. Setting to nil dismisses.
    var inspectorListing: AgentListing? = nil

    /// Registry of locally-implemented Swift tools. Populated at init
    /// with the PR 2 built-ins (`clock.now`, `text.wordcount`). Grows
    /// as more tools ship; MCP-backed tools arrive here via a future
    /// `PluginHost` (see `docs/dev/plugins.md`). The agent loop's
    /// `invoke(name:arguments:)` path consumes it.
    let toolRegistry = ToolRegistry()

    let llama = LlamaRunner()
    let mlx = MLXRunner()
    let ggufDownloader = GGUFDownloader()
    let speechRecognizer = SpeechRecognizer()
    let speechSynthesizer = SpeechSynthesizer()
    let bargeInMonitor = TTSBargeInMonitor()
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
    /// Active tag filter for the History list. AND-match — a
    /// conversation has to carry every tag in the set to be shown.
    /// Empty set = no filter.
    var vaultTagFilter: Set<String> = []
    /// Distinct tag names currently in the vault (refreshed alongside
    /// recents). Drives the tag facet filter in the History section.
    var allVaultTags: [String] = []

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
    /// Continuous-voice ("voice loop") mode: after each assistant reply
    /// finishes being spoken, the mic auto-arms so the user can dictate the
    /// next turn. Requires TTS — toggling this on force-enables TTS;
    /// toggling TTS off clears this flag.
    var continuousVoice: Bool = UserDefaults.standard.bool(forKey: PersistKey.continuousVoice) {
        didSet { UserDefaults.standard.set(continuousVoice, forKey: PersistKey.continuousVoice) }
    }
    /// Sub-toggle of `continuousVoice`: while the loop is on, arm the
    /// barge-in mic monitor during TTS so the user can interrupt by
    /// speaking. Defaults on (headphones use case). Disable when working
    /// on speakers so TTS doesn't self-trigger via mic pickup.
    var bargeInEnabled: Bool = {
        // Default true: no prior key means new install, treat as opted in.
        UserDefaults.standard.object(forKey: PersistKey.bargeInEnabled) as? Bool ?? true
    }() {
        didSet { UserDefaults.standard.set(bargeInEnabled, forKey: PersistKey.bargeInEnabled) }
    }
/// Alternative voice-send trigger: submit after this many seconds without
    /// a new partial transcript. nil = disabled. Works alongside the trigger
    /// phrase; whichever fires first wins. Stored as string since
    /// `UserDefaults.double(forKey:)` can't distinguish 0 from absent.
    var voiceSendSilenceSeconds: Double? = {
        guard let s = UserDefaults.standard.string(forKey: PersistKey.voiceSendSilenceSeconds),
              !s.isEmpty else { return nil }
        return Double(s)
    }() {
        didSet {
            if let v = voiceSendSilenceSeconds {
                UserDefaults.standard.set(String(v), forKey: PersistKey.voiceSendSilenceSeconds)
            } else {
                UserDefaults.standard.removeObject(forKey: PersistKey.voiceSendSilenceSeconds)
            }
        }
    }
    /// Pending silence-timeout submit. Armed on each partial transcript;
    /// fires `send()` if it survives `voiceSendSilenceSeconds` of no updates.
    private var silenceTimer: Task<Void, Never>?

    var generationTask: Task<Void, Never>? = nil
    var loadTask: Task<Void, Never>? = nil

    init() {
        // Wire TTS completion to auto-arm the mic when in voice-loop mode.
        // onFinish fires only on natural completion — a user-initiated Stop
        // (didCancel) skips the callback so the loop doesn't resume over an
        // interrupt.
        speechSynthesizer.onFinish = { [weak self] in
            guard let self else { return }
            self.bargeInMonitor.stop()
            if self.continuousVoice {
                self.startDictation()
            }
        }
        // Any termination path (user Stop, barge-in's own synth.stop, etc.)
        // tears down the barge-in monitor without auto-arming dictation.
        // Barge-in fires startDictation itself before calling synth.stop, so
        // by the time this runs the recognizer is already being brought up.
        speechSynthesizer.onCancel = { [weak self] in
            self?.bargeInMonitor.stop()
        }
        bootstrapAgents()
        refreshWorkspaces()
        logRAGIndexHealth()
    }

    /// Speak the assistant's completed reply and, in voice-loop mode, arm
    /// the barge-in monitor so the user can interrupt by speaking over it.
    /// Called from the Generation stream on successful completion.
    func speakAssistantReply(_ text: String) {
        speechSynthesizer.speak(
            text,
            voiceIdentifier: ttsVoiceId.isEmpty ? nil : ttsVoiceId
        )
        if continuousVoice, bargeInEnabled {
            bargeInMonitor.start { [weak self] in
                guard let self else { return }
                // Order matters: arm the recognizer first so the user's
                // interrupting audio continues into dictation without a gap.
                // `synth.stop` then fires `onCancel` which tears down the
                // monitor (already stopped from its single-shot fire).
                self.startDictation()
                self.speechSynthesizer.stop()
            }
        }
    }

    /// Begin (or resume) on-device dictation feeding the composer. Factored
    /// so the mic button and the voice-loop auto-arm share one path.
    /// Trigger-phrase detection auto-submits; so does a silence timeout if
    /// `voiceSendSilenceSeconds` is set. Otherwise partial transcripts
    /// overwrite `input` each update.
    func startDictation() {
        guard !speechRecognizer.isRecording, !speechRecognizer.isStarting else { return }
        cancelSilenceTimer()
        speechRecognizer.start(baseline: input) { [weak self] text in
            guard let self else { return }
            if let stripped = Self.stripTrailingTrigger(text, phrase: self.voiceSendPhrase) {
                self.cancelSilenceTimer()
                self.input = stripped
                self.speechRecognizer.cancel()
                if self.modelLoaded, !stripped.isEmpty { self.send() }
            } else {
                self.input = text
                self.armSilenceTimer()
            }
        }
    }

    /// Reset the silence-timeout countdown. Called on every partial update
    /// during dictation: as long as new text keeps arriving, the timer
    /// stays armed. When the recognizer goes quiet (user stopped speaking),
    /// no new updates arrive, the timer fires, and the turn is submitted.
    private func armSilenceTimer() {
        silenceTimer?.cancel()
        guard let seconds = voiceSendSilenceSeconds, seconds > 0 else { return }
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.silenceTimer = nil
                let text = self.input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, self.modelLoaded, self.speechRecognizer.isRecording else { return }
                self.speechRecognizer.cancel()
                self.send()
            }
        }
    }

    private func cancelSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    /// Toggle dictation the way the mic button does — the existing inline
    /// logic in `ChatComposer`'s `micButton` is now in one place.
    func toggleDictation() {
        if speechRecognizer.isRecording {
            cancelSilenceTimer()
            speechRecognizer.stop()
        } else {
            startDictation()
        }
    }

    /// Enable or disable voice-loop mode, handling cross-coupling: turning
    /// the loop on force-enables TTS and arms the mic immediately (the loop
    /// needs a starting point). Turning it off is a soft disable — in-flight
    /// dictation or TTS continue.
    func setContinuousVoice(_ on: Bool) {
        continuousVoice = on
        if on {
            ttsEnabled = true
            startDictation()
        }
    }

    /// Called from the TTS toggle in the sidebar. Disabling TTS while the
    /// voice loop is on would break it (no `didFinish` callback to trigger
    /// auto-arm) — clear the loop flag so the UI stays coherent.
    func setTTSEnabled(_ on: Bool) {
        ttsEnabled = on
        if !on {
            continuousVoice = false
            speechSynthesizer.stop()
        }
    }

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
