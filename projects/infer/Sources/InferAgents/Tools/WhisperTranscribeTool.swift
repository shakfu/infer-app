import Foundation

/// Host-supplied speech-to-text backend. A protocol keeps this target free of
/// `AVFoundation` and whisper.cpp, and lets `make test` run without a model.
public protocol AudioTranscriber: Sendable {
    func durationSeconds(of url: URL) async throws -> Double
    func transcribe(url: URL, translate: Bool) async throws -> String
}

/// Transcribes a sandboxed audio file to text. Design and the streaming
/// follow-up: `docs/dev/whisper-ingest-tools.md`.
public struct WhisperTranscribeTool: BuiltinTool {
    public let name: ToolName = "whisper.transcribe"

    /// The bridge has no abort hook, so Stop cannot end a run. This bounds how
    /// long that lasts.
    public static let maxDurationSeconds = 30.0 * 60
    /// Cap on returned bytes, matching `fs.read`.
    public static let maxBytes = 64 * 1024

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Transcribe a local audio file to text. Arguments: {\"path\": \"<absolute or ~/-relative path>\", \"translate\": false}. Set `translate` to true for an English translation. The file must live under an allowed root and be at most \(Int(Self.maxDurationSeconds / 60)) minutes long. Transcription can take minutes and cannot be interrupted. Returns up to \(Self.maxBytes) bytes."
        )
    }

    public let allowedRoots: [URL]
    private let transcriber: any AudioTranscriber

    public init(allowedRoots: [URL], transcriber: any AudioTranscriber) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.transcriber = transcriber
    }

    private struct Args: Decodable {
        let path: String
        let translate: Bool?
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: Data(arguments.utf8))
        } catch {
            return ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)")
        }
        // Resolve symlinks before the root check, so a link inside a root
        // cannot escape it.
        let expanded = (args.path as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let allowed = allowedRoots.contains { candidate.path == $0.path || candidate.path.hasPrefix($0.path + "/") }
        guard allowed else {
            return ToolResult(output: "", error: "path is outside the allowed sandbox")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return ToolResult(output: "", error: "no such file: \(args.path)")
        }
        guard !isDirectory.boolValue else {
            return ToolResult(output: "", error: "path is a directory, not a file")
        }

        do {
            let duration = try await transcriber.durationSeconds(of: candidate)
            guard duration <= Self.maxDurationSeconds else {
                return ToolResult(output: "", error: "audio is \(Int(duration / 60)) minutes long; the limit is \(Int(Self.maxDurationSeconds / 60))")
            }
            let text = try await transcriber.transcribe(url: candidate, translate: args.translate ?? false)
            guard !text.isEmpty else {
                return ToolResult(output: "", error: "transcription produced no text")
            }
            guard text.utf8.count > Self.maxBytes else {
                return ToolResult(output: text)
            }
            let head = String(decoding: text.utf8.prefix(Self.maxBytes), as: UTF8.self)
            return ToolResult(output: head + "\n\n[... truncated at \(Self.maxBytes) bytes ...]")
        } catch {
            return ToolResult(output: "", error: "transcription failed: \(error)")
        }
    }
}
