import Foundation
import AVFoundation
import InferCore

/// Live-mic dictation through whisper.cpp. whisper is batch-only, so the
/// mic feeds a 16 kHz buffer and the whole buffer is re-transcribed every
/// `pollInterval` while recording. That yields partial results, which the
/// trigger-phrase and silence auto-send paths rely on. Re-transcription
/// cost grows with length; dictation turns are short enough for it.
///
/// Uses the model selected under File Transcription; it must already be
/// downloaded (a live mic should not block on a large download).
@MainActor
@Observable
final class WhisperDictation: DictationEngine {
    private(set) var state: SpeechRecognizer.State = .idle
    var isRecording: Bool { state == .recording }
    private(set) var isStarting = false

    private let models: WhisperModelManager
    private let runner: WhisperRunner
    private let engine = AVAudioEngine()
    private var sink: SampleSink?
    private var baseline = ""
    private var onUpdate: ((String) -> Void)?
    private var lastEmitted: String?
    private var pollTask: Task<Void, Never>?
    /// Bumped by every start / stop / cancel, so a transcription or a
    /// model load that finishes late can tell it is stale.
    private var session = 0

    static let pollInterval: Duration = .milliseconds(1500)
    /// Below 0.5 s of audio whisper mostly hallucinates; skip it.
    static let minSamples = 8_000

    init(models: WhisperModelManager, runner: WhisperRunner = .shared) {
        self.models = models
        self.runner = runner
    }

    func start(baseline existingText: String, onUpdate: @escaping (String) -> Void) {
        guard !isStarting, !isRecording else { return }
        let model = models.selected
        guard model.isDownloaded(), let path = try? model.localURL().path else {
            state = .unavailable("Download a Whisper model under File Transcription first.")
            return
        }
        baseline = existingText
        self.onUpdate = onUpdate
        lastEmitted = nil
        session += 1
        let current = session
        isStarting = true
        let runner = self.runner
        Task {
            do {
                try await runner.load(modelPath: path)
            } catch {
                if current == session {
                    isStarting = false
                    state = .error("Could not load Whisper model: \(error)")
                }
                return
            }
            guard current == session else { return }
            isStarting = false
            beginCapture(session: current)
        }
    }

    private func beginCapture(session current: Int) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0,
              let sink = SampleSink(inputFormat: format)
        else {
            state = .error("No audio input device is available.")
            return
        }
        self.sink = sink
        // @Sendable: the tap runs on the realtime audio thread; see the
        // matching note in `SpeechRecognizer.beginRecording`.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            sink.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.sink = nil
            state = .error("Could not start audio engine: \(error.localizedDescription)")
            return
        }
        state = .recording
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled, self.session == current else { return }
                await self.transcribe(session: current)
            }
        }
    }

    private func transcribe(session current: Int) async {
        guard let samples = sink?.snapshot(), samples.count >= Self.minSamples else { return }
        let translate = models.translate
        let text: String
        do {
            text = try await runner.transcribe(samples: samples, translate: translate)
        } catch {
            if current == session { state = .error("Whisper transcription failed: \(error)") }
            return
        }
        guard current == session else { return }
        let cleaned = WhisperText.clean(text)
        // Emit only on change: the silence timer re-arms on every update.
        guard cleaned != lastEmitted else { return }
        lastEmitted = cleaned
        let prefix = baseline.isEmpty || baseline.last == " " || baseline.last == "\n"
            ? baseline
            : baseline + " "
        onUpdate?(prefix + cleaned)
    }

    /// Stops capture and leaves the buffer for a final pass. Returns
    /// whether there was a capture to finish.
    private func endCapture() -> Bool {
        pollTask?.cancel()
        pollTask = nil
        isStarting = false
        let wasCapturing = sink != nil
        if wasCapturing {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if case .recording = state { state = .idle }
        return wasCapturing
    }

    func stop() {
        Task { await stopAndFinalize() }
    }

    func stopAndFinalize() async {
        session += 1
        let current = session
        guard endCapture() else { return }
        await transcribe(session: current)
        if current == session { sink = nil }
    }

    func cancel() {
        session += 1
        _ = endCapture()
        sink = nil
    }
}

/// Converts tap buffers to 16 kHz mono Float32 and accumulates them.
/// Written from the audio thread, read from the main actor.
private final class SampleSink: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat
    private let lock = NSLock()
    private var samples: [Float] = []

    init?(inputFormat: AVAudioFormat) {
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let conv = AVAudioConverter(from: inputFormat, to: out) else { return nil }
        self.outFormat = out
        self.converter = conv
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var err: NSError?
        // `.noDataNow` (not `.endOfStream`) keeps the converter's
        // resampler state primed for the next buffer.
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard err == nil, status != .error, let channel = out.floatChannelData else { return }
        let chunk = UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
