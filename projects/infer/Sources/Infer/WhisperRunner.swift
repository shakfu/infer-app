import Foundation
import AVFoundation
import CWhisperBridge

enum WhisperError: Error, CustomStringConvertible {
    case modelLoadFailed(String)
    case audioDecodeFailed(String)
    case transcribeFailed(Int32)
    case modelNotLoaded
    case downloadFailed(String)

    var description: String {
        switch self {
        case .modelLoadFailed(let s): return "model load failed: \(s)"
        case .audioDecodeFailed(let s): return "audio decode failed: \(s)"
        case .transcribeFailed(let c): return "transcribe failed (code \(c))"
        case .modelNotLoaded: return "whisper model not loaded"
        case .downloadFailed(let s): return "model download failed: \(s)"
        }
    }
}

/// Multilingual ggml whisper models hosted on the canonical HF repo. All of
/// these support both transcription and translation-to-English. The `.en`
/// variants are English-only (can't translate) and intentionally omitted.
enum WhisperModelChoice: String, CaseIterable, Identifiable, Sendable {
    case tiny = "ggml-tiny.bin"
    case base = "ggml-base.bin"
    case small = "ggml-small.bin"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .tiny: return "tiny"
        case .base: return "base"
        case .small: return "small"
        }
    }
    var approxSize: String {
        switch self {
        case .tiny: return "75 MB"
        case .base: return "142 MB"
        case .small: return "466 MB"
        }
    }
    var remoteURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)")!
    }

    static func localDirectory() throws -> URL {
        let fm = FileManager.default
        let appSup = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSup.appendingPathComponent("Infer/whisper", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func localURL() throws -> URL {
        try Self.localDirectory().appendingPathComponent(rawValue)
    }

    func isDownloaded() -> Bool {
        guard let url = try? localURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

/// Owns a single whisper.cpp context. Loading a different model replaces the
/// current one. Transcription is serialized by the actor; concurrent calls
/// queue rather than reentering whisper_full.
actor WhisperRunner {
    static let shared = WhisperRunner()

    private var ctx: OpaquePointer?
    private var loadedPath: String?

    var currentlyLoadedPath: String? { loadedPath }

    /// Idempotent: calling with the same path while already loaded is a no-op.
    func load(modelPath: String) throws {
        if loadedPath == modelPath, ctx != nil { return }
        if let old = ctx {
            whisper_bridge_free(old)
            ctx = nil
            loadedPath = nil
        }
        guard let c = modelPath.withCString({ whisper_bridge_init_from_file($0) }) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        ctx = c
        loadedPath = modelPath
    }

    /// Decode the given audio file to 16 kHz mono Float32 and run whisper on
    /// it. Returns concatenated segment text, trimmed.
    func transcribeFile(url: URL, translate: Bool) throws -> String {
        guard let ctx else { throw WhisperError.modelNotLoaded }
        let pcm = try AudioDecoder.decode16kMono(url: url)
        guard !pcm.isEmpty else { throw WhisperError.audioDecodeFailed("no audio samples") }

        let threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        let status: Int32 = pcm.withUnsafeBufferPointer { buf in
            whisper_bridge_transcribe(
                ctx,
                buf.baseAddress,
                Int32(buf.count),
                translate,
                threads
            )
        }
        if status != 0 { throw WhisperError.transcribeFailed(status) }

        let n = whisper_bridge_n_segments(ctx)
        var parts: [String] = []
        parts.reserveCapacity(Int(n))
        for i in 0..<n {
            if let p = whisper_bridge_segment_text(ctx, i) {
                parts.append(String(cString: p))
            }
        }
        return parts.joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Release the context. Call from AppDelegate.applicationWillTerminate
    /// to match the llama / MLX cleanup pattern. Idempotent.
    func shutdown() {
        if let c = ctx { whisper_bridge_free(c); ctx = nil }
        loadedPath = nil
    }

    // No deinit: same reason as LlamaRunner — actor-isolated C pointers
    // aren't reachable from a Swift 6 nonisolated deinit. `shutdown()` is
    // the cleanup path, called from `AppDelegate.applicationWillTerminate`.
}

// MARK: - Audio decoding

enum AudioDecoder {
    /// Decode any AVAudioFile-supported format (wav, mp3, m4a, flac, aiff,
    /// mp4 audio track, …) to 16 kHz mono Float32 — whisper.cpp's required
    /// input format. The entire file is loaded into memory; for v1 this is
    /// acceptable (even a 2-hour lecture at 16 kHz mono is ~460 MB, which
    /// fits comfortably on any modern Mac).
    static func decode16kMono(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw WhisperError.audioDecodeFailed(error.localizedDescription)
        }

        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw WhisperError.audioDecodeFailed("could not allocate source buffer")
        }
        do {
            try file.read(into: srcBuf)
        } catch {
            throw WhisperError.audioDecodeFailed("read failed: \(error.localizedDescription)")
        }

        // Fast path: already 16 kHz mono Float32.
        let already =
            srcFormat.sampleRate == 16_000 &&
            srcFormat.channelCount == 1 &&
            srcFormat.commonFormat == .pcmFormatFloat32
        if already, let data = srcBuf.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(srcBuf.frameLength)))
        }

        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw WhisperError.audioDecodeFailed("cannot create 16 kHz mono destination format")
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw WhisperError.audioDecodeFailed("AVAudioConverter init failed")
        }

        let ratio = dstFormat.sampleRate / srcFormat.sampleRate
        let dstCapacity = AVAudioFrameCount(Double(frameCount) * ratio + 16_384)
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity) else {
            throw WhisperError.audioDecodeFailed("could not allocate destination buffer")
        }

        var supplied = false
        var err: NSError?
        let status = converter.convert(to: dstBuf, error: &err) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return srcBuf
        }
        if let err {
            throw WhisperError.audioDecodeFailed(err.localizedDescription)
        }
        if status == .error {
            throw WhisperError.audioDecodeFailed("AVAudioConverter reported error")
        }

        guard let data = dstBuf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(dstBuf.frameLength)))
    }
}

// MARK: - Model manager (download + settings)

private enum WhisperPersistKey {
    static let model = "infer.whisperModel"
    static let translate = "infer.whisperTranslate"
}

@MainActor
@Observable
final class WhisperModelManager {
    var selected: WhisperModelChoice
    var translate: Bool
    var downloadProgress: Double? = nil
    /// User-visible status line (e.g. "Downloading base (142 MB)…"). nil
    /// when idle.
    var statusMessage: String? = nil

    private var downloadDelegate: WhisperDownloadDelegate?
    private var downloadSession: URLSession?

    init() {
        if let raw = UserDefaults.standard.string(forKey: WhisperPersistKey.model),
           let m = WhisperModelChoice(rawValue: raw) {
            self.selected = m
        } else {
            self.selected = .base
        }
        self.translate = UserDefaults.standard.bool(forKey: WhisperPersistKey.translate)
    }

    func setSelected(_ m: WhisperModelChoice) {
        selected = m
        UserDefaults.standard.set(m.rawValue, forKey: WhisperPersistKey.model)
    }

    func setTranslate(_ v: Bool) {
        translate = v
        UserDefaults.standard.set(v, forKey: WhisperPersistKey.translate)
    }

    /// Ensure the currently-selected model is present on disk; download it if
    /// not. Progress is reported through `downloadProgress` (0…1).
    func ensureDownloaded() async throws -> URL {
        let model = selected
        let dest = try model.localURL()
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        statusMessage = "Downloading \(model.label) (\(model.approxSize))…"
        downloadProgress = 0
        defer {
            statusMessage = nil
            downloadProgress = nil
        }
        try await downloadFile(from: model.remoteURL, to: dest)
        return dest
    }

    private func downloadFile(from url: URL, to dest: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = WhisperDownloadDelegate(
                onProgress: { [weak self] frac in
                    Task { @MainActor in self?.downloadProgress = frac }
                },
                onFinish: { [weak self] result in
                    switch result {
                    case .success(let tmp):
                        do {
                            try? FileManager.default.removeItem(at: dest)
                            try FileManager.default.createDirectory(
                                at: dest.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try FileManager.default.moveItem(at: tmp, to: dest)
                            cont.resume()
                        } catch {
                            cont.resume(throwing: WhisperError.downloadFailed(error.localizedDescription))
                        }
                    case .failure(let err):
                        cont.resume(throwing: WhisperError.downloadFailed(err.localizedDescription))
                    }
                    Task { @MainActor in
                        self?.downloadSession?.finishTasksAndInvalidate()
                        self?.downloadSession = nil
                        self?.downloadDelegate = nil
                    }
                }
            )
            self.downloadDelegate = delegate
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            self.downloadSession = session
            session.downloadTask(with: url).resume()
        }
    }
}

// MARK: - In-app audio recorder

/// Captures the microphone to a .wav file in
/// `~/Library/Application Support/Infer/recordings/`. Format is the input
/// node's native format (typically 48 kHz Float32) — `AudioDecoder` handles
/// the 16 kHz mono resample at transcribe time.
@MainActor
@Observable
final class AudioFileRecorder {
    enum State: Equatable {
        case idle
        case recording
        case error(String)
    }

    var state: State = .idle
    var duration: TimeInterval = 0
    var isRecording: Bool { state == .recording }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var startDate: Date?
    private var timer: Timer?

    static func recordingsDirectory() throws -> URL {
        let fm = FileManager.default
        let appSup = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSup.appendingPathComponent("Infer/recordings", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Begin recording. Returns the destination URL. On failure, sets
    /// `state = .error(...)` and throws.
    @discardableResult
    func start() throws -> URL {
        guard !isRecording else {
            throw NSError(
                domain: "AudioFileRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "already recording"]
            )
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            state = .error("No audio input device is available.")
            throw NSError(
                domain: "AudioFileRecorder", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no input device"]
            )
        }

        let dir = try Self.recordingsDirectory()
        let stamp = Self.filenameStamp()
        let url = dir.appendingPathComponent("recording-\(stamp).wav")

        let newFile = try AVAudioFile(forWriting: url, settings: format.settings)
        self.file = newFile
        self.fileURL = url

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            // Tap runs on the audio render thread. AVAudioFile.write is
            // documented as thread-safe; we rely on that here.
            try? self?.file?.write(from: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.file = nil
            self.fileURL = nil
            try? FileManager.default.removeItem(at: url)
            state = .error("Could not start audio engine: \(error.localizedDescription)")
            throw error
        }

        startDate = Date()
        duration = 0
        state = .recording

        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.duration = Date().timeIntervalSince(start)
            }
        }
        self.timer = t
        return url
    }

    /// Stop and flush the file. Returns the written URL, or nil if not
    /// recording.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        timer?.invalidate(); timer = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let url = fileURL
        file = nil
        fileURL = nil
        startDate = nil
        state = .idle
        return url
    }

    /// Abort and discard the in-flight recording file.
    func cancel() {
        let url = fileURL
        _ = stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        duration = 0
    }

    private static func filenameStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

private final class WhisperDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: (Double) -> Void
    let onFinish: (Result<URL, Error>) -> Void
    private var finished = false
    private let lock = NSLock()

    init(
        onProgress: @escaping (Double) -> Void,
        onFinish: @escaping (Result<URL, Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    private func claimFinish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard claimFinish() else { return }
        // URLSession deletes `location` as soon as this callback returns, so
        // move it into a temp file that outlives the delegate.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            onFinish(.success(tmp))
        } catch {
            onFinish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        guard claimFinish() else { return }
        onFinish(.failure(error))
    }
}
