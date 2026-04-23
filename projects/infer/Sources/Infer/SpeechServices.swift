import Foundation
import Speech
import AVFoundation

// MARK: - Speech recognition (dictation)

@MainActor
@Observable
final class SpeechRecognizer {
    enum State: Equatable {
        case idle
        case unavailable(String)
        case unauthorized
        case recording
        case error(String)
    }

    var state: State = .idle
    var isRecording: Bool { state == .recording }
    /// True between the user tapping the mic and `state` actually becoming
    /// `.recording` (during auth / engine start). Used by the button to
    /// suppress double-taps and show an immediate visual response.
    var isStarting: Bool = false

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onUpdate: ((String) -> Void)?

    /// Text already committed when recording started. Partial transcripts are
    /// appended to this baseline so the caller's field isn't clobbered.
    private var baseline: String = ""

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    var supportsOnDevice: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    func toggle(baseline existingText: String, onUpdate: @escaping (String) -> Void) {
        if isRecording {
            stop()
        } else if !isStarting {
            start(baseline: existingText, onUpdate: onUpdate)
        }
    }

    func start(baseline existingText: String, onUpdate: @escaping (String) -> Void) {
        guard !isStarting, state != .recording else { return }
        guard let recognizer else {
            state = .unavailable("Speech recognition is not available for this locale.")
            return
        }
        guard recognizer.isAvailable else {
            state = .unavailable("Speech recognizer is temporarily unavailable.")
            return
        }
        self.baseline = existingText
        self.onUpdate = onUpdate
        self.isStarting = true

        // Fast path: already authorized -> skip the async round-trip so the
        // mic button reflects recording state on the same runloop as the tap.
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            beginRecording(recognizer: recognizer)
            isStarting = false
            return
        }

        // @Sendable: TCC invokes this completion on a background QoS queue,
        // and without it the closure inherits SpeechRecognizer's @MainActor
        // isolation, which traps in swift_task_isCurrentExecutor before the
        // Task{} hop can run.
        SFSpeechRecognizer.requestAuthorization { @Sendable [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                defer { self.isStarting = false }
                switch status {
                case .authorized:
                    self.beginRecording(recognizer: recognizer)
                case .denied, .restricted, .notDetermined:
                    self.state = .unauthorized
                @unknown default:
                    self.state = .unauthorized
                }
            }
        }
    }

    private func beginRecording(recognizer: SFSpeechRecognizer) {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Prefer on-device, but fall back to the system path if the on-device
        // model isn't actually ready (supportsOnDeviceRecognition == true
        // doesn't guarantee the asset is downloaded, and Dictation must also
        // be enabled in System Settings > Keyboard > Dictation).
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            state = .error("No audio input device is available.")
            return
        }
        // @Sendable detaches the closure from SpeechRecognizer's @MainActor
        // isolation — AVAudioEngine invokes the tap on a realtime audio thread,
        // and an isolated closure would trip swift_task_isCurrent's queue
        // assertion and crash with EXC_BREAKPOINT.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            req.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            teardown()
            state = .error("Could not start audio engine: \(error.localizedDescription)")
            return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.emit(text)
                    if result.isFinal { self.teardown() }
                }
                if let error {
                    let nsErr = error as NSError
                    // Code 1110 ("No speech detected") is benign.
                    // Code 301 on macOS can fire on stop — also benign.
                    let benign: Set<Int> = [1110, 301, 216]
                    if !benign.contains(nsErr.code) {
                        print("SFSpeechRecognizer error \(nsErr.domain) \(nsErr.code): \(nsErr.localizedDescription)")
                        self.state = .error("Recognition failed (\(nsErr.code)): \(nsErr.localizedDescription)")
                    }
                    self.teardown()
                }
            }
        }
        state = .recording
    }

    private func emit(_ partial: String) {
        let prefix = baseline.isEmpty || baseline.last == " " || baseline.last == "\n"
            ? baseline
            : baseline + " "
        onUpdate?(prefix + partial)
    }

    /// Stop capturing audio; the recognizer will deliver one last (final) callback.
    func stop() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        request?.endAudio()
        if case .recording = state { state = .idle }
    }

    /// Abort without waiting for a final callback; drops in-flight audio.
    func cancel() {
        task?.cancel()
        teardown()
    }

    private func teardown() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        request = nil
        task = nil
        if case .recording = state { state = .idle }
    }
}

// MARK: - Text-to-speech

@MainActor
@Observable
final class SpeechSynthesizer {
    private let synth = AVSpeechSynthesizer()
    private(set) var isSpeaking: Bool = false
    /// Invoked when an utterance completes naturally. NOT fired on
    /// `didCancel` (i.e. when `stop()` interrupts playback) — the caller
    /// can distinguish "finished speaking" from "user stopped it".
    var onFinish: (() -> Void)?
    /// Invoked when playback is interrupted via `stop()` / `didCancel`.
    /// Complement of `onFinish` — lets observers clean up ancillary state
    /// (e.g. a barge-in monitor) without auto-arming anything.
    var onCancel: (() -> Void)?

    private let delegateBox: Delegate

    init() {
        self.delegateBox = Delegate()
        self.synth.delegate = delegateBox
        delegateBox.owner = self
    }

    /// All installed voices, sorted by language then name. Some higher-quality
    /// voices require a manual download in System Settings.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.name < rhs.name
            }
    }

    func speak(_ text: String, voiceIdentifier: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utt = AVSpeechUtterance(string: trimmed)
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            utt.voice = v
        } else {
            utt.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        synth.speak(utt)
        isSpeaking = true
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    fileprivate func delegateSaidFinished(interrupted: Bool) {
        isSpeaking = synth.isSpeaking
        // Only fire onFinish on natural completion. Stop()/didCancel fires
        // onCancel instead so observers can distinguish the two paths — a
        // voice-loop shouldn't auto-arm over a deliberate interrupt, but a
        // barge-in monitor still needs to tear down.
        guard !synth.isSpeaking else { return }
        if interrupted {
            onCancel?()
        } else {
            onFinish?()
        }
    }

    final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        nonisolated(unsafe) weak var owner: SpeechSynthesizer?
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in self.owner?.delegateSaidFinished(interrupted: false) }
        }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            Task { @MainActor in self.owner?.delegateSaidFinished(interrupted: true) }
        }
    }
}

// MARK: - TTS barge-in (voice-loop interrupt)

/// Watches the mic during TTS playback and fires once when sustained input
/// level crosses a threshold — the "user is trying to interrupt" signal.
///
/// Not `@MainActor`: the AVAudioEngine tap closure runs off-main and needs
/// to mutate timing state synchronously. Shared state is lock-protected;
/// the single user-visible side effect (the callback) hops to main.
final class TTSBargeInMonitor: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    // Lock-protected state.
    private var tapInstalled = false
    private var running = false
    private var aboveSince: Date?
    private var fired = false
    private var onBargeIn: (@MainActor @Sendable () -> Void)?

    /// Tunables; kept as code constants for v1. Thresholds that need tuning
    /// in the field can graduate to the Voice sidebar later.
    private let thresholdDBFS: Float = -30.0
    private let sustainSeconds: TimeInterval = 0.2

    /// Start monitoring. `onBargeIn` is invoked on the main actor at most
    /// once per `start` call; the monitor self-stops on fire. Silently
    /// returns if already running, if no input device is available, or if
    /// the audio engine fails to start — callers keep working without
    /// barge-in in that session.
    func start(onBargeIn: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            lock.unlock()
            FileHandle.standardError.write(Data("barge-in: no input device\n".utf8))
            return
        }
        self.onBargeIn = onBargeIn
        self.aboveSince = nil
        self.fired = false
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        lock.lock()
        tapInstalled = true
        lock.unlock()

        do {
            engine.prepare()
            try engine.start()
            lock.lock()
            running = true
            lock.unlock()
        } catch {
            FileHandle.standardError.write(
                Data("barge-in: engine start failed: \(error)\n".utf8)
            )
            teardown()
        }
    }

    func stop() {
        teardown()
    }

    private func teardown() {
        lock.lock()
        let wasRunning = running
        let hadTap = tapInstalled
        running = false
        tapInstalled = false
        onBargeIn = nil
        aboveSince = nil
        fired = false
        lock.unlock()

        if wasRunning, engine.isRunning {
            engine.stop()
        }
        if hadTap {
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channel = channels[0]

        var sumSquares: Float = 0
        for i in 0..<frames {
            let s = channel[i]
            sumSquares += s * s
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        let dBFS = 20 * log10(max(rms, 1e-6))
        let now = Date()

        lock.lock()
        if fired || !running {
            lock.unlock()
            return
        }
        let shouldFire: Bool
        if dBFS > thresholdDBFS {
            if aboveSince == nil {
                aboveSince = now
                shouldFire = false
            } else if let start = aboveSince,
                      now.timeIntervalSince(start) >= sustainSeconds {
                fired = true
                shouldFire = true
            } else {
                shouldFire = false
            }
        } else {
            aboveSince = nil
            shouldFire = false
        }
        let callback = shouldFire ? onBargeIn : nil
        lock.unlock()

        if let callback {
            Task { @MainActor in
                callback()
            }
        }
    }
}
