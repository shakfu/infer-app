import Foundation
@testable import InferAgents

/// In-memory MCP transport used by `MCPClientTests`. Records every
/// frame sent by the client and exposes a `respond` API for the test
/// to push synthetic server responses through the inbound stream.
///
/// Threading: the inbound continuation is `nonisolated`-safe (Swift's
/// `AsyncThrowingStream` makes `yield` callable from any isolation),
/// and `outboundFrames` is guarded by an actor so concurrent sends
/// don't tear the array.
final class MockMCPTransport: MCPTransport, @unchecked Sendable {

    let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let recorder = SendRecorder()

    init() {
        var c: AsyncThrowingStream<Data, Error>.Continuation!
        self.messages = AsyncThrowingStream(bufferingPolicy: .unbounded) { cont in
            c = cont
        }
        self.continuation = c
    }

    func send(_ frame: Data) async throws {
        await recorder.append(frame)
    }

    func shutdown() async {
        continuation.finish()
    }

    /// Push a server response into the inbound stream. The test
    /// drives the wire format directly so we can assert the client's
    /// JSON-RPC handling without spinning up a real server.
    func respond(rawJSON: String) {
        continuation.yield(Data(rawJSON.utf8))
    }

    /// Push a typed JSON-RPC response by id. Convenience for the
    /// common "I just sent request N, here's its result" pattern.
    func respondResult(id: Int, resultJSON: String) {
        let frame = #"{"jsonrpc":"2.0","id":\#(id),"result":\#(resultJSON)}"#
        respond(rawJSON: frame)
    }

    func respondError(id: Int, code: Int, message: String) {
        let frame = #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(code),"message":"\#(message)"}}"#
        respond(rawJSON: frame)
    }

    /// Frames the client sent us, in order. Each is one JSON-RPC
    /// envelope (request or notification).
    func sentFrames() async -> [Data] { await recorder.frames }

    /// Decoded methods from the sent frames, in order. Useful for
    /// asserting the handshake sequence.
    func sentMethods() async -> [String] {
        let frames = await recorder.frames
        var methods: [String] = []
        for frame in frames {
            if let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
               let m = obj["method"] as? String {
                methods.append(m)
            }
        }
        return methods
    }

    private actor SendRecorder {
        var frames: [Data] = []
        func append(_ frame: Data) { frames.append(frame) }
    }
}
