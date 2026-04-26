import Foundation

/// Bidirectional message channel between an `MCPClient` and one MCP
/// server. The client speaks newline-delimited JSON (NDJSON, per the
/// MCP stdio spec): each frame is one JSON object followed by `\n`,
/// with no embedded newlines inside the JSON.
///
/// Two implementations land in v1: `StdioMCPTransport` (subprocess
/// over Foundation.Process) and a mock used by tests
/// (`Tests/InferAgentsTests/MCP/MockMCPTransport.swift`). Splitting
/// the seam at the transport keeps the client testable without
/// spawning real subprocesses.
public protocol MCPTransport: Sendable {
    /// Inbound frames, decoded line-by-line. Yields once per JSON
    /// object the server emitted (sans trailing newline). Throws on
    /// transport-level errors; finishes when the server closes its
    /// stdout.
    var messages: AsyncThrowingStream<Data, Error> { get }

    /// Send one JSON object. Implementations are responsible for
    /// appending the trailing `\n` and serialising writes so two
    /// concurrent calls don't interleave bytes.
    func send(_ frame: Data) async throws

    /// Terminate the underlying channel: kill the subprocess, close
    /// pipes, finish the inbound stream. Idempotent; safe to call
    /// during teardown without first checking state.
    func shutdown() async
}

/// Stdio transport: launches an MCP server as a child process, writes
/// frames to its stdin, reads frames from its stdout, drains stderr
/// to a logger callback (or `/dev/null`).
///
/// The reader runs on a detached `Task` that pulls bytes from the
/// pipe's `FileHandle`, splits on `\n`, and emits one frame per
/// continuation `yield`. Reads are blocking on `availableData`; the
/// task exits cleanly when EOF arrives or `shutdown()` is called.
public final class StdioMCPTransport: MCPTransport, @unchecked Sendable {

    /// Optional callback for the server's stderr lines. The host
    /// typically routes this to `LogCenter` so misbehaving servers
    /// surface in the Console tab.
    public typealias StderrSink = @Sendable (String) -> Void

    public let messages: AsyncThrowingStream<Data, Error>

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let writeQueue = DispatchQueue(label: "mcp.stdio.write", qos: .userInitiated)
    private let shutdownState = ShutdownState()

    private final class ShutdownState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func consume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return true }
            done = true
            return false
        }
    }

    /// Spawn `executable` with `arguments` and the given environment.
    /// `cwd` is the child's working directory; nil = inherit. Throws
    /// on launch failure; once it returns the process is running and
    /// the inbound stream is live.
    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        cwd: URL? = nil,
        stderrSink: StderrSink? = nil
    ) throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if let environment {
            p.environment = environment
        }
        if let cwd {
            p.currentDirectoryURL = cwd
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        var continuationOut: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { c in
            continuationOut = c
        }

        self.process = p
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.messages = stream
        self.continuation = continuationOut

        try p.run()

        // Reader: detached so it doesn't pin the calling actor.
        // Splits on `\n` and yields one frame per JSON object.
        // `availableData` returns empty Data on EOF.
        Task.detached { [stdoutPipe, continuation] in
            var buffer = Data()
            while true {
                let chunk = stdoutPipe.fileHandleForReading.availableData
                if chunk.isEmpty {
                    continuation.finish()
                    return
                }
                buffer.append(chunk)
                while let nlRange = buffer.range(of: Data([0x0A])) {
                    let line = buffer.subdata(in: 0..<nlRange.lowerBound)
                    buffer.removeSubrange(0..<nlRange.upperBound)
                    if !line.isEmpty {
                        continuation.yield(line)
                    }
                }
            }
        }

        // Stderr drain: best-effort. Lines flushed to the callback so
        // a chatty server's diagnostics aren't lost. Shares the same
        // detached-task pattern as stdout.
        if let stderrSink {
            Task.detached { [stderrPipe] in
                var buffer = Data()
                while true {
                    let chunk = stderrPipe.fileHandleForReading.availableData
                    if chunk.isEmpty { return }
                    buffer.append(chunk)
                    while let nlRange = buffer.range(of: Data([0x0A])) {
                        let line = buffer.subdata(in: 0..<nlRange.lowerBound)
                        buffer.removeSubrange(0..<nlRange.upperBound)
                        if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                            stderrSink(text)
                        }
                    }
                }
            }
        } else {
            // Drain to /dev/null so the pipe doesn't fill and block
            // the child on stderr writes.
            Task.detached { [stderrPipe] in
                while !stderrPipe.fileHandleForReading.availableData.isEmpty {}
            }
        }
    }

    public func send(_ frame: Data) async throws {
        // Serialise writes through a dispatch queue so two concurrent
        // requests can't interleave bytes inside one frame.
        let pipe = self.stdinPipe
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    try pipe.fileHandleForWriting.write(contentsOf: frame)
                    try pipe.fileHandleForWriting.write(contentsOf: Data([0x0A]))
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func shutdown() async {
        if shutdownState.consume() { return }
        // Closing stdin signals graceful exit to most servers; the
        // subsequent terminate is the hard fallback.
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        continuation.finish()
    }
}
