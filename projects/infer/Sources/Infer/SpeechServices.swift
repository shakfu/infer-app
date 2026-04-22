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

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
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
        // Only fire onFinish on natural completion. If the user pressed Stop,
        // the synth delivers didCancel and we skip the callback so a
        // continuous-voice loop won't auto-arm over a deliberate interrupt.
        if !interrupted, !synth.isSpeaking {
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
