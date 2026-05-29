import Foundation
import InferAppCore

/// Scriptable `ChatRunner` for `ChatEngine` tests. Mirrors the mock in
/// `InferAppCoreTests` (which is not reachable from this target — and
/// `InferAppCoreTests` cannot import `InferSession` without a dependency
/// cycle). Records every call so tests can assert *what* the engine fed the
/// runner and *in what order* — e.g. that `regenerate` / `editAndResend`
/// issue a `setHistory` before `respondToUser` (rebuild mode) while a plain
/// `send` does not (incremental mode).
actor MockChatRunner: ChatRunner {
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

    init(scripted: [Scripted] = []) {
        self.scripted = scripted
    }

    func setHistory(_ turns: [ChatTurn]) async throws {
        calls.append(.setHistory(turns))
    }

    func respondToUser(_ text: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        calls.append(.respondToUser(text: text, maxTokens: maxTokens))
        let next: Scripted? = scripted.isEmpty ? nil : scripted.removeFirst()
        return AsyncThrowingStream { continuation in
            guard let next else { continuation.finish(); return }
            for chunk in next.chunks { continuation.yield(chunk) }
            if let err = next.error {
                continuation.finish(throwing: err)
            } else {
                continuation.finish()
            }
        }
    }

    func requestStop() async { calls.append(.requestStop) }
    func resetConversation() async { calls.append(.resetConversation) }
    func rewindLastTurn() async { calls.append(.rewindLastTurn) }

    func recordedCalls() -> [RecordedCall] { calls }
}
