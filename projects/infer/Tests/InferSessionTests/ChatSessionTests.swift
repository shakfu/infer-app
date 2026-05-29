import XCTest
import InferCore
@testable import InferSession

/// Stub `CloudClient` yielding canned deltas so `ChatSession` can be driven
/// end-to-end without the network. Records the messages it was handed on the
/// most recent call so tests can assert the transcript the session built.
private final class StubCloudClient: CloudClient, @unchecked Sendable {
    let deltas: [String]
    private let lock = NSLock()
    private var _calls: [[CloudChatMessage]] = []
    var calls: [[CloudChatMessage]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    init(deltas: [String]) { self.deltas = deltas }

    func streamChat(
        messages: [CloudChatMessage],
        model: String,
        params: CloudGenerationParams
    ) -> AsyncThrowingStream<String, Error> {
        lock.lock(); _calls.append(messages); lock.unlock()
        let deltas = self.deltas
        return AsyncThrowingStream { continuation in
            for d in deltas { continuation.yield(d) }
            continuation.finish()
        }
    }
}

final class ChatSessionTests: XCTestCase {
    private func session(_ stub: StubCloudClient) -> ChatSession {
        ChatSession(clientFactory: { _, _ in stub })
    }

    private func configure(_ session: ChatSession, systemPrompt: String? = nil) async throws {
        try await session.configure(
            provider: .openai,
            model: "gpt-test",
            apiKey: "sk-test-key",
            systemPrompt: systemPrompt,
            params: CloudGenerationParams(maxTokens: 256)
        )
    }

    /// The session assembles streamed deltas into the full reply and forwards
    /// each chunk to `onChunk` in order.
    func testSendAssemblesAndStreamsChunks() async throws {
        let stub = StubCloudClient(deltas: ["Hel", "lo, ", "world"])
        let s = session(stub)
        try await configure(s)

        let collected = ChunkCollector()
        let reply = try await s.send("hi", maxTokens: 256) { chunk in
            collected.append(chunk)
        }

        XCTAssertEqual(reply, "Hello, world")
        XCTAssertEqual(collected.chunks, ["Hel", "lo, ", "world"])
    }

    /// `configure` puts the system prompt at index 0 of the outbound
    /// transcript, and `send` appends the user turn after it.
    func testSystemPromptLeadsTranscript() async throws {
        let stub = StubCloudClient(deltas: ["ok"])
        let s = session(stub)
        try await configure(s, systemPrompt: "you are terse")

        _ = try await s.send("ping")

        let outbound = try XCTUnwrap(stub.calls.last)
        XCTAssertEqual(outbound.first?.role, .system)
        XCTAssertEqual(outbound.first?.content, "you are terse")
        XCTAssertEqual(outbound.last?.role, .user)
        XCTAssertEqual(outbound.last?.content, "ping")
    }

    /// State lives in the runner: a second `send` carries the prior
    /// user+assistant turns, so the conversation continues.
    func testMultiTurnAccumulatesHistory() async throws {
        let stub = StubCloudClient(deltas: ["reply"])
        let s = session(stub)
        try await configure(s)

        _ = try await s.send("first")
        _ = try await s.send("second")

        let secondOutbound = try XCTUnwrap(stub.calls.last)
        // first-user, first-assistant, second-user
        XCTAssertEqual(secondOutbound.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(secondOutbound.map(\.content), ["first", "reply", "second"])
    }

    /// `reset` clears the transcript while keeping the provider configured,
    /// so a subsequent `send` starts a fresh conversation.
    func testResetClearsHistory() async throws {
        let stub = StubCloudClient(deltas: ["reply"])
        let s = session(stub)
        try await configure(s)

        _ = try await s.send("first")
        await s.reset()
        _ = try await s.send("again")

        let outbound = try XCTUnwrap(stub.calls.last)
        XCTAssertEqual(outbound.map(\.content), ["again"])
    }
}

/// Thread-safe collector for the `@Sendable` onChunk callback.
private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _chunks: [String] = []
    func append(_ s: String) { lock.lock(); _chunks.append(s); lock.unlock() }
    var chunks: [String] { lock.lock(); defer { lock.unlock() }; return _chunks }
}
