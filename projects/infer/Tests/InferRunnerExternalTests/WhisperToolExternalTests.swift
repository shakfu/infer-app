import InferAgents
import XCTest
@testable import Infer

/// Runs `whisper.transcribe` through the real `WhisperRunner` on speech made
/// by `say`. Skips when the selected Whisper model is not downloaded.
@MainActor
final class WhisperToolExternalTests: XCTestCase {
    func testTranscribesSpokenAudio() async throws {
        let models = WhisperModelManager()
        // ggml's Metal backend asserts at process exit if a context is still
        // alive; the app frees it in `applicationWillTerminate`.
        addTeardownBlock { await WhisperRunner.shared.shutdown() }
        try XCTSkipUnless(models.selected.isDownloaded(), "Whisper model not downloaded")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("speech.aiff")

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audio.path, "The quick brown fox jumps over the lazy dog."]
        try say.run()
        say.waitUntilExit()
        try XCTSkipUnless(say.terminationStatus == 0, "say could not produce audio")

        let tool = WhisperTranscribeTool(allowedRoots: [dir], transcriber: WhisperToolTranscriber(models: models))
        let args = try JSONSerialization.data(withJSONObject: ["path": audio.path])
        let result = try await tool.invoke(arguments: String(decoding: args, as: UTF8.self))

        XCTAssertNil(result.error)
        XCTAssertTrue(result.output.lowercased().contains("fox"), "got: \(result.output)")
    }
}
