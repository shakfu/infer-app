import Foundation

/// Tool wrapper around `QuartoRunner`. Conforms to both `BuiltinTool`
/// (the simple one-shot path used by hosts that don't care about
/// progress) and `StreamingBuiltinTool` (used by hosts that wire
/// `AgentContext.invokeToolStreaming`, surfacing per-line stderr from
/// the Quarto process as `AgentEvent.toolProgress`).
///
/// Argument schema:
/// ```
/// {
///   "markdown": "<the .qmd source>",
///   "to": "html|pdf|docx|revealjs|typst|latex",
///   "extraArgs": ["--self-contained"]   // optional
/// }
/// ```
///
/// On success, returns `ToolResult(output: "<absolute path to rendered file>")`.
/// On failure, returns `ToolResult(error: "<message + log tail>")` so the
/// model sees what went wrong and can suggest a remediation (most often
/// "install Quarto via `brew install quarto`").
public struct QuartoRenderTool: StreamingBuiltinTool {
    public let name: ToolName = "builtin.quarto.render"

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Render a Quarto / markdown document to an output format using a \
                local Quarto installation. Arguments: \
                {"markdown": "<full .qmd source including YAML front-matter>", \
                "to": "<format>", "extraArgs": ["--optional"]}. \
                Supported formats: \
                `html` (web page), \
                `pdf` (article via LaTeX/Typst), \
                `docx` (Word document), \
                `pptx` (PowerPoint slides — use `#` for section title slides and `##` for content slides with bullets), \
                `odt` (OpenDocument), \
                `revealjs` (browser slides — same `#`/`##` slide rules as `pptx`), \
                `beamer` (LaTeX slides), \
                `typst` (Typst source), \
                `latex` (LaTeX source), \
                `epub` (e-book), \
                `gfm` (GitHub-flavored markdown). \
                The `markdown` argument should be a complete Quarto document: \
                YAML front-matter (`--- title: \"...\" author: \"...\" ---`) \
                followed by the body. Returns the absolute path to the \
                rendered file. If Quarto is not installed, returns an error \
                telling the user to run `brew install quarto`.
                """
        )
    }

    public let locator: QuartoLocator
    public let runner: QuartoRunner

    public init(locator: QuartoLocator = QuartoLocator(), runner: QuartoRunner = QuartoRunner()) {
        self.locator = locator
        self.runner = runner
    }

    private struct Args: Decodable {
        let markdown: String
        let to: String
        let extraArgs: [String]?
    }

    private enum ParseOutcome {
        case ok(Args, QuartoRunner.Output)
        case error(ToolResult)
    }

    private func parse(_ arguments: String) -> ParseOutcome {
        guard let data = arguments.data(using: .utf8) else {
            return .error(ToolResult(output: "", error: "arguments not UTF-8"))
        }
        let parsed: Args
        do {
            parsed = try JSONDecoder().decode(Args.self, from: data)
        } catch {
            return .error(ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)"))
        }
        guard let format = QuartoRunner.Output(rawValue: parsed.to.lowercased()) else {
            let allowed = QuartoRunner.Output.allCases.map(\.rawValue).joined(separator: ", ")
            return .error(ToolResult(output: "", error: "unknown output format '\(parsed.to)'. Allowed: \(allowed)"))
        }
        return .ok(parsed, format)
    }

    // MARK: - Simple async path

    public func invoke(arguments: String) async throws -> ToolResult {
        let parsed: Args
        let format: QuartoRunner.Output
        switch parse(arguments) {
        case .error(let r): return r
        case .ok(let a, let f): parsed = a; format = f
        }
        guard let install = await locator.resolve() else {
            return ToolResult(
                output: "",
                error: "Quarto not found on PATH. Install via `brew install quarto` or set the path in Settings."
            )
        }
        do {
            let result = try await runner.render(
                markdown: parsed.markdown,
                to: format,
                quartoPath: install.url.path,
                extraArgs: parsed.extraArgs ?? []
            )
            return ToolResult(output: result.outputURL.path)
        } catch let error as QuartoRunner.RenderError {
            return ToolResult(output: "", error: describe(error))
        } catch {
            return ToolResult(output: "", error: "render failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Streaming path

    public func invokeStreaming(arguments: String) -> AsyncThrowingStream<ToolEvent, Error> {
        let parsed: Args
        let format: QuartoRunner.Output
        switch parse(arguments) {
        case .error(let r):
            return AsyncThrowingStream { c in
                c.yield(.result(r))
                c.finish()
            }
        case .ok(let a, let f):
            parsed = a; format = f
        }
        let locator = self.locator
        let runner = self.runner
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let install = await locator.resolve() else {
                    continuation.yield(.result(ToolResult(
                        output: "",
                        error: "Quarto not found on PATH. Install via `brew install quarto` or set the path in Settings."
                    )))
                    continuation.finish()
                    return
                }
                let inner = runner.renderStreaming(
                    markdown: parsed.markdown,
                    to: format,
                    quartoPath: install.url.path,
                    extraArgs: parsed.extraArgs ?? []
                )
                do {
                    for try await event in inner {
                        switch event {
                        case .log(let line):
                            continuation.yield(.log(line))
                        case .finished(let result):
                            continuation.yield(.result(ToolResult(output: result.outputURL.path)))
                        case .failed(let message, let log):
                            let tail = String(log.suffix(2000))
                            continuation.yield(.result(ToolResult(
                                output: "",
                                error: tail.isEmpty ? message : "\(message)\n---\n\(tail)"
                            )))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.result(ToolResult(
                        output: "",
                        error: "render failed: \(error.localizedDescription)"
                    )))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func describe(_ error: QuartoRunner.RenderError) -> String {
        switch error {
        case .quartoNotExecutable(let path):
            return "Quarto path is not executable: \(path)"
        case .spawnFailed(let message):
            return "could not start Quarto: \(message)"
        case .nonZeroExit(_, let log):
            let tail = String(log.suffix(2000))
            return tail.isEmpty ? "Quarto render failed" : "Quarto render failed:\n\(tail)"
        case .outputMissing(let expected, _):
            return "render reported success but the output file is missing: \(expected)"
        }
    }
}
