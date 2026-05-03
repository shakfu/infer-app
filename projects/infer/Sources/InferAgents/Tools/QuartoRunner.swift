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

        // Scan workDir for the rendered file rather than assuming
        // `input.<ext>`. Quarto honors `--output X.pptx` / `-o X.pptx`
        // from extraArgs, and earlier versions of this code that
        // hardcoded the input name reported "render reported success
        // but output file is missing" whenever the model passed
        // --output. Filtering by extension is enough: input.qmd is
        // .qmd, not the output extension, and any sibling artifacts
        // Quarto leaves (input_files/, .tex, image scratch) carry
        // different extensions or aren't files.
        let ext = outputExtension(for: output)
        let outputURL: URL
        do {
            let contents = try fm.contentsOfDirectory(
                at: workDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            )
            let matches = contents.filter { $0.pathExtension == ext }
            // If multiple candidates somehow exist (Quarto writes the
            // intended output and a stale leftover from an earlier
            // run), pick the newest by mtime so we hand back the file
            // this invocation produced.
            guard let newest = matches.max(by: { a, b in
                let aMod = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bMod = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return aMod < bMod
            }) else {
                continuation.yield(.failed(
                    message: "render reported success but no .\(ext) output found in \(workDir.lastPathComponent)",
                    log: combinedLog
                ))
                continuation.finish()
                return
            }
            outputURL = newest
        } catch {
            continuation.yield(.failed(
                message: "could not enumerate workDir to locate output: \(error.localizedDescription)",
                log: combinedLog
            ))
            continuation.finish()
            return
        }

        // Move the output out of the about-to-be-deleted temp dir into a
        // stable per-render location under the user's caches. Filename
        // is `YYMMDD-<slug>.<ext>`; slug derived from the markdown's
        // YAML `title:` so users skimming the cache in Finder can tell
        // entries apart by topic.
        let stableURL: URL
        do {
            stableURL = try Self.moveToCaches(outputURL, slug: Self.deriveSlug(from: markdown))
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

    /// Move the rendered file into the cache directory under
    /// `YYMMDD-<slug>.<ext>`. If a same-day same-slug render already
    /// exists (re-rendering the same titled doc on the same day),
    /// append `-2`, `-3`, … to avoid clobbering. Worth bounding the
    /// retry loop so a permission / mount issue on the cache dir
    /// doesn't spin forever — 1000 attempts is plenty for the "user
    /// renders the same doc many times in one day" case.
    private static func moveToCaches(_ source: URL, slug: String) throws -> URL {
        let fm = FileManager.default
        let caches = try cacheDirectory()
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let prefix = datePrefix()
        let ext = source.pathExtension
        let base = "\(prefix)-\(slug)"
        for attempt in 0..<1000 {
            let suffix = attempt == 0 ? "" : "-\(attempt + 1)"
            let name = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            let dest = caches.appendingPathComponent(name)
            if !fm.fileExists(atPath: dest.path) {
                try fm.moveItem(at: source, to: dest)
                return dest
            }
        }
        throw RenderError.spawnFailed(
            "could not find a free cache filename under \(caches.path) for \(base).\(ext)"
        )
    }

    /// `YYMMDD` in the user's local time zone. POSIX locale so the
    /// digits are ASCII regardless of the user's regional settings.
    private static func datePrefix(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyMMdd"
        return formatter.string(from: date)
    }

    /// Pull a slug out of the markdown's YAML frontmatter `title:` if
    /// present, slugify it, and bound the length. Falls back to
    /// `untitled` for documents with no frontmatter or no `title:` —
    /// the date prefix still disambiguates same-day renders, and the
    /// collision-suffix loop in `moveToCaches` handles the case where
    /// several `untitled` renders happen in one day.
    static func deriveSlug(from markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        // Frontmatter must open with `---` on the first non-empty line.
        // Anything else is treated as no-frontmatter -> untitled.
        guard let firstNonEmpty = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              firstNonEmpty.trimmingCharacters(in: .whitespaces) == "---" else {
            return "untitled"
        }
        var sawOpener = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !sawOpener {
                if trimmed == "---" { sawOpener = true }
                continue
            }
            if trimmed == "---" { break }                    // closer; no title found
            guard trimmed.hasPrefix("title:") else { continue }
            let raw = trimmed.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes (single, double, or smart) — Quarto
            // accepts unquoted, "double", and 'single' forms equally.
            let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{2018}\u{2019}\u{201C}\u{201D}"))
            let slug = slugify(unquoted)
            return slug.isEmpty ? "untitled" : slug
        }
        return "untitled"
    }

    /// Lowercase, collapse non-alphanumeric runs into single hyphens,
    /// strip leading/trailing hyphens, cap at 60 chars. Filesystem-safe
    /// across HFS+ / APFS / NTFS / ext4. Doesn't try to be locale-aware
    /// (no transliteration of accented characters or CJK — those just
    /// get reduced to runs of hyphens, which is acceptable for a cache
    /// hint; the YYMMDD prefix carries the disambiguating weight).
    static func slugify(_ s: String) -> String {
        var out = ""
        var lastWasDash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(60))
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
