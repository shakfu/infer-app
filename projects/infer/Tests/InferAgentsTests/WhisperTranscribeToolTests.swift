import XCTest
@testable import InferAgents

private struct StubFailure: Error, CustomStringConvertible {
    var description: String { "whisper model not loaded" }
}

private final class StubTranscriber: AudioTranscriber, @unchecked Sendable {
    var duration = 60.0
    var result: Result<String, StubFailure> = .success("hello")
    private(set) var calls: [(url: URL, translate: Bool)] = []

    func durationSeconds(of url: URL) async throws -> Double { duration }

    func transcribe(url: URL, translate: Bool) async throws -> String {
        calls.append((url, translate))
        return try result.get()
    }
}

final class WhisperTranscribeToolTests: XCTestCase {
    private var root: URL!
    private var outside: URL!
    private var audio: URL!
    private var stub: StubTranscriber!
    private var tool: WhisperTranscribeTool!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        audio = root.appendingPathComponent("memo.wav")
        try Data([0]).write(to: audio)
        stub = StubTranscriber()
        tool = WhisperTranscribeTool(allowedRoots: [root], transcriber: stub)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func invoke(path: String, translate: Bool? = nil) async throws -> ToolResult {
        var payload: [String: Any] = ["path": path]
        if let translate { payload["translate"] = translate }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await tool.invoke(arguments: String(decoding: data, as: UTF8.self))
    }

    func testReturnsTranscriptAndDefaultsToNoTranslation() async throws {
        let result = try await invoke(path: audio.path)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "hello")
        XCTAssertEqual(stub.calls.map(\.translate), [false])
    }

    func testForwardsTranslate() async throws {
        _ = try await invoke(path: audio.path, translate: true)
        XCTAssertEqual(stub.calls.map(\.translate), [true])
    }

    func testRejectsPathOutsideSandbox() async throws {
        let file = outside.appendingPathComponent("secret.wav")
        try Data([0]).write(to: file)
        let result = try await invoke(path: file.path)
        XCTAssertEqual(result.error, "path is outside the allowed sandbox")
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testRejectsSymlinkEscape() async throws {
        let file = outside.appendingPathComponent("secret.wav")
        try Data([0]).write(to: file)
        let link = root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let result = try await invoke(path: link.path)
        XCTAssertEqual(result.error, "path is outside the allowed sandbox")
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testRejectsSiblingWithRootPrefix() async throws {
        let sibling = URL(fileURLWithPath: root.path + "-other")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let file = sibling.appendingPathComponent("a.wav")
        try Data([0]).write(to: file)
        let result = try await invoke(path: file.path)
        XCTAssertEqual(result.error, "path is outside the allowed sandbox")
    }

    func testRejectsMissingFileAndDirectory() async throws {
        let missing = try await invoke(path: root.appendingPathComponent("none.wav").path)
        XCTAssertTrue(missing.error?.hasPrefix("no such file") == true)
        let directory = try await invoke(path: root.path)
        XCTAssertEqual(directory.error, "path is a directory, not a file")
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testRejectsMalformedArguments() async throws {
        let result = try await tool.invoke(arguments: "{}")
        XCTAssertTrue(result.error?.hasPrefix("could not parse arguments") == true)
    }

    func testDurationCapRefusesBeforeTranscribing() async throws {
        stub.duration = WhisperTranscribeTool.maxDurationSeconds + 1
        let result = try await invoke(path: audio.path)
        XCTAssertEqual(result.error, "audio is 30 minutes long; the limit is 30")
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testAudioAtTheDurationCapIsAllowed() async throws {
        stub.duration = WhisperTranscribeTool.maxDurationSeconds
        let result = try await invoke(path: audio.path)
        XCTAssertNil(result.error)
    }

    func testBackendFailureIsReported() async throws {
        stub.result = .failure(StubFailure())
        let result = try await invoke(path: audio.path)
        XCTAssertEqual(result.error, "transcription failed: whisper model not loaded")
    }

    func testEmptyTranscriptIsAnError() async throws {
        stub.result = .success("")
        let result = try await invoke(path: audio.path)
        XCTAssertEqual(result.error, "transcription produced no text")
    }

    func testLongTranscriptIsTruncatedWithMarker() async throws {
        stub.result = .success(String(repeating: "x", count: WhisperTranscribeTool.maxBytes + 10))
        let result = try await invoke(path: audio.path)
        XCTAssertTrue(result.output.hasSuffix("[... truncated at \(WhisperTranscribeTool.maxBytes) bytes ...]"))
        XCTAssertLessThan(result.output.utf8.count, WhisperTranscribeTool.maxBytes + 100)
    }
}
