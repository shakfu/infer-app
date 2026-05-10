import Foundation
@testable import InferAppCore

/// Scriptable `ChatRunner` for tests. The chat-VM analogue of
/// `MockAgentRunner` (in `InferAgentsTests`). Records every call so
/// tests can assert *what* the VM fed the runner and *in what order*,
/// not just the user-visible outcome — which is the most common class
/// of regression in the real app (e.g. a `setHistory` call that fires
/// after `sendUserMessage` rather than before, or never fires at all).
///
/// One scripted entry is consumed per `sendUserMessage`. Out-of-script
/// calls return an empty stream that finishes immediately — the test
/// asserts on `calls` to catch unmet expectations, the same trade-off
/// `MockAgentRunner` made.
actor MockChatRunner: ChatRunner {
    /// One scripted assistant response. `chunks` is emitted in order;
    /// if `error` is non-nil, the stream throws after the chunks
    /// (use an empty `chunks` array to throw immediately).
    struct Scripted: Sendable {
        var chunks: [String]
        var error: Error?

        init(chunks: [String], error: Error? = nil) {
            self.chunks = chunks
            self.error = error
        }

        static func text(_ s: String) -> Scripted { .init(chunks: [s]) }
        static func chunks(_ c: [String]) -> Scripted { .init(chunks: c) }
        static func failure(_ e: Error) -> Scripted { .init(chunks: [], error: e) }
    }

    enum RecordedCall: Sendable, Equatable {
        case setHistory([ChatTurn])
        case respondToUser(text: String, maxTokens: Int)
        case requestStop
        case resetConversation
        case rewindLastTurn
    }

    private(set) var calls: [RecordedCall] = []
    private var scripted: [Scripted]
    /// Active continuation for the in-flight `sendUserMessage` stream.
    /// `requestStop` finishes it (with `CancellationError`) so tests can
    /// model the user-clicks-Stop flow without waiting on a real timer.
    private var activeContinuation: AsyncThrowingStream<String, Error>.Continuation?

    init(scripted: [Scripted] = []) {
        self.scripted = scripted
    }

    // MARK: ChatRunner

    func setHistory(_ turns: [ChatTurn]) async throws {
        calls.append(.setHistory(turns))
    }

    func respondToUser(_ text: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        calls.append(.respondToUser(text: text, maxTokens: maxTokens))
        let next: Scripted? = scripted.isEmpty ? nil : scripted.removeFirst()
        // Capture for requestStop before opening the stream — the
        // continuation is set inside the stream's builder closure and
        // hopped onto the actor via a Task to keep isolation honest.
        return AsyncThrowingStream { continuation in
            let captureTask = Task { [weak self] in
                await self?.setActiveContinuation(continuation)
            }
            _ = captureTask
            guard let next else {
                continuation.finish()
                return
            }
            for chunk in next.chunks {
                continuation.yield(chunk)
            }
            if let err = next.error {
                continuation.finish(throwing: err)
            } else {
                continuation.finish()
            }
        }
    }

    func requestStop() async {
        calls.append(.requestStop)
        activeContinuation?.finish(throwing: CancellationError())
        activeContinuation = nil
    }

    func resetConversation() async {
        calls.append(.resetConversation)
    }

    func rewindLastTurn() async {
        calls.append(.rewindLastTurn)
    }

    // MARK: Helpers

    private func setActiveContinuation(_ c: AsyncThrowingStream<String, Error>.Continuation) {
        self.activeContinuation = c
    }

    /// Test helper: read the recorded calls without going through the
    /// `nonisolated` accessor pattern.
    func recordedCalls() -> [RecordedCall] { calls }
}
