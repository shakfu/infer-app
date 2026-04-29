import XCTest
@testable import InferCore

/// Stub `CloudClient` that yields canned text deltas, then either finishes
/// or throws. Used to drive `CloudRunner` end-to-end without touching the
/// network. `Sendable` because the runner stores the factory as a sendable
/// closure.
private final class StubCloudClient: CloudClient, @unchecked Sendable {
    enum Outcome {
        case complete(deltas: [String])
        case throwing(deltas: [String], error: Error)
    }
    let outcome: Outcome
    /// Captures the messages the runner sent on the most recent stream call.
    /// Locked because tests inspect from outside the actor.
    private let lock = NSLock()
    private var _captured: [CloudChatMessage] = []
    var captured: [CloudChatMessage] {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    init(_ outcome: Outcome) { self.outcome = outcome }

    func streamChat(
        messages: [CloudChatMessage],
        model: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        _captured = messages
        lock.unlock()
        let outcome = self.outcome
        return AsyncThrowingStream { continuation in
            Task {
                switch outcome {
                case .complete(let deltas):
                    for d in deltas {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        continuation.yield(d)
                        // Tiny sleep so cancellation tests have a window.
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                    continuation.finish()
                case .throwing(let deltas, let err):
                    for d in deltas { continuation.yield(d) }
                    continuation.finish(throwing: err)
                }
            }
        }
    }
}

final class CloudRunnerTests: XCTestCase {
    private func makeRunner(_ stub: StubCloudClient) -> CloudRunner {
        CloudRunner(clientFactory: { _, _ in stub })
    }

    private func configure(_ runner: CloudRunner, systemPrompt: String? = "you are helpful") async throws {
        try await runner.configure(
            provider: .openai,
            model: "gpt-test",
            apiKey: "sk-test-key",
            systemPrompt: systemPrompt,
            temperature: 0.5,
            topP: 0.9
        )
    }

    func testStreamsDeltasAndCommitsAssistantTurn() async throws {
        let stub = StubCloudClient(.complete(deltas: ["Hel", "lo, ", "world"]))
        let runner = makeRunner(stub)
        try await configure(runner)

        var collected = ""
        let stream = await runner.sendUserMessage("hi")
        for try await piece in stream { collected += piece }
        XCTAssertEqual(collected, "Hello, world")

        let transcript = await runner.transcriptSnapshot()
        // system + user + assistant.
        XCTAssertEqual(transcript.count, 3)
        XCTAssertEqual(transcript[0].role, .system)
        XCTAssertEqual(transcript[1].role, .user)
        XCTAssertEqual(transcript[1].content, "hi")
        XCTAssertEqual(transcript[2].role, .assistant)
        XCTAssertEqual(transcript[2].content, "Hello, world")
    }

    func testRefusesSendWhenNotConfigured() async {
        let runner = CloudRunner(clientFactory: { _, _ in
            StubCloudClient(.complete(deltas: []))
        })
        let stream = await runner.sendUserMessage("hi")
        do {
            for try await _ in stream {}
            XCTFail("expected throw")
        } catch let CloudError.notConfigured {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConfigureRejectsEmptyKey() async {
        let runner = CloudRunner(clientFactory: { _, _ in
            StubCloudClient(.complete(deltas: []))
        })
        do {
            try await runner.configure(
                provider: .openai,
                model: "gpt-test",
                apiKey: "",
                systemPrompt: nil,
                temperature: 0.5,
                topP: 0.9
            )
            XCTFail("expected missingKey")
        } catch let CloudError.missingKey {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConfigureRejectsBadCompatEndpoint() async {
        let runner = CloudRunner(clientFactory: { _, _ in
            StubCloudClient(.complete(deltas: []))
        })
        do {
            try await runner.configure(
                provider: .openaiCompatible(
                    name: "Bad",
                    baseURL: URL(string: "http://api.example.com")!
                ),
                model: "x",
                apiKey: "k",
                systemPrompt: nil,
                temperature: 0.5,
                topP: 0.9
            )
            XCTFail("expected invalidEndpoint")
        } catch let CloudError.invalidEndpoint {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConfigureAcceptsLoopbackCompatEndpoint() async throws {
        let runner = CloudRunner(clientFactory: { _, _ in
            StubCloudClient(.complete(deltas: ["ok"]))
        })
        try await runner.configure(
            provider: .openaiCompatible(
                name: "Local",
                baseURL: URL(string: "http://localhost:11434/v1")!
            ),
            model: "llama3",
            apiKey: "k",
            systemPrompt: nil,
            temperature: 0.5,
            topP: 0.9
        )
        let id = await runner.loadedModelId
        XCTAssertEqual(id, "llama3")
    }

    func testRollsBackUserTurnOnError() async throws {
        struct Boom: Error {}
        let stub = StubCloudClient(.throwing(deltas: ["partial"], error: Boom()))
        let runner = makeRunner(stub)
        try await configure(runner, systemPrompt: nil)

        let stream = await runner.sendUserMessage("hi")
        do {
            for try await _ in stream {}
            XCTFail("expected throw")
        } catch {
            // expected
        }

        let transcript = await runner.transcriptSnapshot()
        // No system prompt this time, and the failed user turn was rolled
        // back, so the transcript should be empty.
        XCTAssertEqual(transcript.count, 0)
    }

    func testResetConversationKeepsSystemPrompt() async throws {
        let stub = StubCloudClient(.complete(deltas: ["a"]))
        let runner = makeRunner(stub)
        try await configure(runner)

        let s1 = await runner.sendUserMessage("hi")
        for try await _ in s1 {}

        await runner.resetConversation()
        let transcript = await runner.transcriptSnapshot()
        XCTAssertEqual(transcript.count, 1)
        XCTAssertEqual(transcript[0].role, .system)
    }

    func testUpdateSettingsResetsHistoryWhenSystemPromptChanges() async throws {
        let stub = StubCloudClient(.complete(deltas: ["a"]))
        let runner = makeRunner(stub)
        try await configure(runner, systemPrompt: "v1")

        let s1 = await runner.sendUserMessage("hi")
        for try await _ in s1 {}
        var transcript = await runner.transcriptSnapshot()
        XCTAssertEqual(transcript.count, 3)

        await runner.updateSettings(systemPrompt: "v2", temperature: 0.5, topP: 0.9)
        transcript = await runner.transcriptSnapshot()
        XCTAssertEqual(transcript.count, 1)
        XCTAssertEqual(transcript[0].content, "v2")
    }

    func testUpdateSettingsKeepsHistoryWhenSystemPromptUnchanged() async throws {
        let stub = StubCloudClient(.complete(deltas: ["a"]))
        let runner = makeRunner(stub)
        try await configure(runner, systemPrompt: "v1")

        let s1 = await runner.sendUserMessage("hi")
        for try await _ in s1 {}

        await runner.updateSettings(systemPrompt: "v1", temperature: 0.1, topP: 0.5)
        let transcript = await runner.transcriptSnapshot()
        XCTAssertEqual(transcript.count, 3)
    }

    func testShutdownClearsState() async throws {
        let stub = StubCloudClient(.complete(deltas: ["a"]))
        let runner = makeRunner(stub)
        try await configure(runner)

        await runner.shutdown()
        let transcript = await runner.transcriptSnapshot()
        XCTAssertEqual(transcript.count, 0)
        let id = await runner.loadedModelId
        XCTAssertNil(id)
    }
}
