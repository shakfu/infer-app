import Foundation
@testable import InferAgents

/// Deterministic `AgentRunner` for tests.
///
/// Each call to `decode` consumes the next entry from `responses` and
/// returns it as a single-chunk stream (or, when split into chunks,
/// emits each chunk in order so callers can exercise streaming-aware
/// code). Unused entries cause an XCTFail-style failure on the next
/// call so unmet expectations don't pass silently — mock returns a
/// stream that yields no chunks and finishes, which downstream
/// asserts will catch.
final class MockAgentRunner: AgentRunner, @unchecked Sendable {
    /// One scripted response. `chunks` is the sequence of strings the
    /// mock will emit before finishing the stream. Use a single-element
    /// array for the common case; multiple chunks exercise streaming
    /// observers.
    struct Scripted: Sendable {
        let chunks: [String]
        init(_ chunks: [String]) { self.chunks = chunks }
        init(_ single: String) { self.chunks = [single] }
    }

    private let lock = NSLock()
    private var responses: [Scripted]
    /// Recorded transcripts the loop passed in, in call order. Tests
    /// assert against this to verify the loop fed tool results back
    /// before the second decode, etc.
    private(set) var calls: [[TranscriptMessage]] = []

    init(_ responses: [Scripted]) {
        self.responses = responses
    }

    convenience init(_ texts: [String]) {
        self.init(texts.map { Scripted($0) })
    }

    func decode(
        messages: [TranscriptMessage],
        params: DecodingParams
    ) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        calls.append(messages)
        let scripted: Scripted? = responses.isEmpty ? nil : responses.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            guard let scripted else {
                continuation.finish()
                return
            }
            for chunk in scripted.chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
