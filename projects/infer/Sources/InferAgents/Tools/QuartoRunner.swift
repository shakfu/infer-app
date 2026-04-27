import Foundation

/// Drives an external `quarto render` process. Two surfaces:
///
/// - `render(...)` — block-and-return for short renders (HTML, DOCX) or
///   for callers that don't care about progress. Throws on render
///   failure with the captured stderr tail.
/// - `renderStreaming(...)` — emits `.log` events line-by-line from
///   the process's stderr (Quarto is chatty during PDF/Typst renders),
///   then a single terminal `.finished` or `.failed`. Suitable for the
///   tool-loop streaming path so the user sees progress instead of a
///   silent multi-second spinner.
///
/// Both paths cooperate with `Task.cancel()` — cancellation calls
/// `Process.terminate()` and cleans up the temp directory.
public actor QuartoRunner {
    public enum Output: String, Sendable, CaseIterable, Codable {
        case html, pdf, docx, pptx, odt, revealjs, beamer, typst, latex, epub, gfm
    }

    public struct RenderResult: Sendable, Equatable {
        public let outputURL: URL
        public let log: String

        public init(outputURL: URL, log: String) {
            self.outputURL = outputURL
            self.log = log
        }
    }

    public enum RenderEvent: Sendable, Equatable {
        case log(String)
        case finished(RenderResult)
        case failed(message: String, log: String)
    }

    public enum RenderError: Error, Equatable, Sendable {
        case quartoNotExecutable(path: String)
        case spawnFailed(String)
        case nonZeroExit(code: Int32, log: String)
        case outputMissing(expected: String, log: String)
    }

    public init() {}

    // MARK: - Simple async surface

    /// Render `markdown` to `output`, returning the result when the
    /// process exits with code 0. Throws on any failure with the
    /// captured stderr included in the error.
    public func render(
        markdown: String,
        to output: Output,
        quartoPath: String,
        extraArgs: [String] = []
    ) async throws -> RenderResult {
        let stream = renderStreaming(
            markdown: markdown,
            to: output,
            quartoPath: quartoPath,
            extraArgs: extraArgs
        )
        var log = ""
        for try await event in stream {
            switch event {
            case .log(let line):
                log.append(line)
                log.append("\n")
            case .finished(let result):
                return result
            case .failed(let message, let combined):
                throw RenderError.nonZeroExit(code: -1, log: combined.isEmpty ? message : combined)
            }
        }
        throw RenderError.spawnFailed("stream ended without a terminal event")
    }

    // MARK: - Streaming surface

    /// Stream stderr lines as `.log` events while the render runs, then
    /// emit exactly one terminal event (`.finished` on success,
    /// `.failed` on non-zero exit or a missing output file).
    ///
    /// The stream is `nonisolated` so callers can iterate without
    /// holding the actor for the whole render — the work happens on a
    /// detached task internally.
    public nonisolated func renderStreaming(
        markdown: String,
        to output: Output,
        quartoPath: String,
        extraArgs: [String] = []
    ) -> AsyncThrowingStream<RenderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                await Self.runRender(
                    markdown: markdown,
                    to: output,
                    quartoPath: quartoPath,
                    extraArgs: extraArgs,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Implementation

    private static func runRender(
        markdown: String,
        to output: Output,
        quartoPath: String,
        extraArgs: [String],
        continuation: AsyncThrowingStream<RenderEvent, Error>.Continuation
    ) async {
        guard FileManager.default.isExecutableFile(atPath: quartoPath) else {
            continuation.finish(throwing: RenderError.quartoNotExecutable(path: quartoPath))
            return
        }

        // Temp directory holds the input .qmd and is also Quarto's
        // working dir; the rendered output lands next to the input.
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("quarto-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            continuation.finish(throwing: RenderError.spawnFailed("could not create temp dir: \(error.localizedDescription)"))
            return
        }
        defer { try? fm.removeItem(at: workDir) }

        let inputURL = workDir.appendingPathComponent("input.qmd")
        do {
            try markdown.write(to: inputURL, atomically: true, encoding: .utf8)
        } catch {
            continuation.finish(throwing: RenderError.spawnFailed("could not write input: \(error.localizedDescription)"))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: quartoPath)
        process.arguments = ["render", "input.qmd", "--to", output.rawValue] + extraArgs
        process.currentDirectoryURL = workDir
        // Inherit a minimal PATH that covers the bundled tool dirs Quarto
        // probes (deno, pandoc) when installed via Homebrew or pkg.
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = "\(existing):\(extraPath)"
        } else {
            env["PATH"] = extraPath
        }
        process.environment = env

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            continuation.finish(throwing: RenderError.spawnFailed(error.localizedDescription))
            return
        }

        // Fire-and-forget cancellation watchdog — `Task.cancel` on the
        // outer detached task propagates here via `Task.isCancelled`.
        let cancelTask = Task {
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { cancelTask.cancel() }

        // Consume stderr line-by-line. `availableData` blocks until
        // there's data or EOF; we hop off the calling task with a
        // detached child so the main consumer keeps draining.
        var combinedLog = ""
        let stderrHandle = stderrPipe.fileHandleForReading
        var pending = Data()
        while true {
            let chunk = stderrHandle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let nlIndex = pending.firstIndex(of: 0x0A) {
                let lineData = pending.prefix(upTo: nlIndex)
                pending.removeSubrange(0...nlIndex)
                if let line = String(data: lineData, encoding: .utf8) {
                    let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    combinedLog.append(stripped)
                    combinedLog.append("\n")
                    continuation.yield(.log(stripped))
                }
            }
        }
        if !pending.isEmpty, let tail = String(data: pending, encoding: .utf8) {
            let stripped = tail.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if !stripped.isEmpty {
                combinedLog.append(stripped)
                combinedLog.append("\n")
                continuation.yield(.log(stripped))
            }
        }

        process.waitUntilExit()
        // Drain stdout for completeness — Quarto sometimes emits the
        // output path on stdout. Append to the log so the model has the
        // full picture when something goes wrong.
        let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if let s = String(data: stdoutTail, encoding: .utf8), !s.isEmpty {
            combinedLog.append(s)
        }

        if process.terminationStatus != 0 {
            continuation.yield(.failed(
                message: "quarto exited with code \(process.terminationStatus)",
                log: combinedLog
            ))
            continuation.finish()
            return
        }

        let outputURL = workDir.appendingPathComponent("input.\(outputExtension(for: output))")
        guard fm.fileExists(atPath: outputURL.path) else {
            continuation.yield(.failed(
                message: "render reported success but output file is missing",
                log: combinedLog
            ))
            continuation.finish()
            return
        }

        // Move the output out of the about-to-be-deleted temp dir into a
        // stable per-render location under the user's caches.
        let stableURL: URL
        do {
            stableURL = try Self.moveToCaches(outputURL)
        } catch {
            continuation.yield(.failed(
                message: "could not stage output: \(error.localizedDescription)",
                log: combinedLog
            ))
            continuation.finish()
            return
        }

        continuation.yield(.finished(RenderResult(outputURL: stableURL, log: combinedLog)))
        continuation.finish()
    }

    private static func outputExtension(for output: Output) -> String {
        switch output {
        case .html, .revealjs: return "html"
        case .pdf, .beamer:    return "pdf"
        case .docx:            return "docx"
        case .pptx:            return "pptx"
        case .odt:             return "odt"
        case .typst:           return "typ"
        case .latex:           return "tex"
        case .epub:            return "epub"
        case .gfm:             return "md"
        }
    }

    private static func moveToCaches(_ source: URL) throws -> URL {
        let fm = FileManager.default
        let caches = try cacheDirectory()
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let dest = caches.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        try fm.moveItem(at: source, to: dest)
        return dest
    }

    /// Directory under `~/Library/Caches/` where successful renders are
    /// staged. Public so the host app's Tools panel can reveal / clear
    /// it without duplicating the path. The directory is created lazily
    /// on the first render — `cacheDirectory()` returns the URL whether
    /// or not the dir exists yet, so callers that just want to show it
    /// in Finder need to handle the not-yet-created case themselves.
    public static func cacheDirectory() throws -> URL {
        try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("quarto-renders", isDirectory: true)
    }
}
