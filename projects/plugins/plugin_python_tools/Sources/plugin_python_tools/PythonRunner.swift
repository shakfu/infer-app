import Foundation

/// Result of a single subprocess invocation. `timedOut` is `true` when
/// the runner had to `terminate()` the process; in that case
/// `exitCode` is whatever the OS reports for SIGTERM (`15`) and the
/// model still gets whatever was written before the kill.
public struct PythonRunResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool

    public init(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

public enum PythonRunnerError: Error, Equatable, Sendable {
    case spawnFailed(String)
}

/// Bounds for `timeout_seconds`. The default applies when the tool
/// call doesn't specify one; the cap is the maximum the model can
/// request — we refuse `timeout_seconds: 99999` so a runaway agent
/// can't pin a process forever.
public enum PythonTimeoutBounds {
    public static let defaultSeconds: Int = 10
    public static let maxSeconds: Int = 120
    public static let minSeconds: Int = 1

    /// Clamp a model-supplied (or default) value into the valid range.
    public static func clamp(_ requested: Int?) -> Int {
        let v = requested ?? defaultSeconds
        return min(max(v, minSeconds), maxSeconds)
    }
}

public struct PythonRunner: Sendable {
    public let pythonPath: URL
    public init(pythonPath: URL) { self.pythonPath = pythonPath }

    /// Spawn `python3 -` with `code` on stdin, capture stdout/stderr,
    /// kill on timeout. `extraEnv` is merged over the parent
    /// environment (used by `python.eval` to pass the expression
    /// without quoting it into the code stream).
    public func run(
        code: String,
        timeoutSeconds: Int,
        extraEnv: [String: String] = [:]
    ) async throws -> PythonRunResult {
        let process = Process()
        process.executableURL = pythonPath
        process.arguments = ["-"]

        // Per-invocation working dir, removed on return. Keeps each
        // call isolated; tools that need persistence can write to
        // ~/Documents via `fs.write` instead.
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "plugin_python_tools-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        process.currentDirectoryURL = tmpDir

        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            process.environment = env
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw PythonRunnerError.spawnFailed(String(describing: error))
        }

        // Write the script to stdin and close so python sees EOF.
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(code.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        // Drain pipes concurrently. If we waited until process exit
        // and only then read, a python program that prints more than
        // the OS pipe buffer (~16-64 KB on macOS) would block on
        // `print()` and never exit.
        async let stdoutData = readAll(handle: stdoutPipe.fileHandleForReading)
        async let stderrData = readAll(handle: stderrPipe.fileHandleForReading)

        let timedOut = await waitWithTimeout(process: process, seconds: timeoutSeconds)

        let out = await stdoutData
        let err = await stderrData

        return PythonRunResult(
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self),
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }

    private func readAll(handle: FileHandle) async -> Data {
        await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? handle.readToEnd()) ?? Data()
                cont.resume(returning: data)
            }
        }
    }

    /// Wait for the process to exit, killing it if `seconds` elapses
    /// first. Returns `true` iff we had to issue the kill. Uses a
    /// shared flag rather than racing two tasks' return values — the
    /// termination-handler task always fires when the process exits
    /// (including as a side-effect of `terminate()`), so racing
    /// return values picks the wrong winner ~half the time.
    private func waitWithTimeout(process: Process, seconds: Int) async -> Bool {
        let didTimeout = TimeoutFlag()
        let exitGate = ExitGate()

        // Wire the exit signal BEFORE the caller has had a chance to
        // start the process? The caller already started it — we set
        // the handler here. macOS guarantees `terminationHandler` is
        // invoked even if assigned after exit, by re-firing on
        // assignment when the process has already terminated. (If a
        // future macOS revision changes that, we'd need to set the
        // handler before `process.run()`.)
        process.terminationHandler = { _ in
            Task { await exitGate.signal() }
        }

        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            if process.isRunning {
                await didTimeout.set()
                process.terminate()
                try? await Task.sleep(nanoseconds: 200_000_000)
                if process.isRunning { process.interrupt() }
            }
        }

        await exitGate.wait()
        timer.cancel()
        return await didTimeout.value
    }
}

/// Tiny actors used by `waitWithTimeout` to coordinate the timer task
/// and the exit-signal callback without racing return values.
private actor ExitGate {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if fired { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
        }
    }

    func signal() {
        fired = true
        if let cont = continuation {
            continuation = nil
            cont.resume()
        }
    }
}

private actor TimeoutFlag {
    var value = false
    func set() { value = true }
}
