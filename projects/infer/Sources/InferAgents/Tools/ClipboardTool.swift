import Foundation
import AppKit

/// Read the current clipboard's text contents. Empty string when the
/// clipboard holds no string-flavoured representation (image, file URL,
/// nothing).
///
/// Argument schema: `{}`. The tool ignores any argument the model
/// passes — clipboard reads have no parameters.
///
/// The pasteboard is injectable so unit tests can use a private
/// pasteboard (`NSPasteboard(name:)`) and not stomp the user's clipboard
/// during `make test`. The chat VM wires in `NSPasteboard.general`.
public struct ClipboardGetTool: BuiltinTool, @unchecked Sendable {
    public let name: ToolName = "clipboard.get"

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Read the current contents of the macOS clipboard as text. Call with an empty parameters object: {}. Returns the clipboard's string, or an empty string if the clipboard does not hold text. Use when the user says \"summarise what I just copied\" or refers to \"the clipboard\"."
        )
    }

    /// `NSPasteboard` is mutable shared state; `@unchecked Sendable` on
    /// the tool struct accommodates older Swift toolchains that don't
    /// recognise `NSPasteboard` as Sendable. Functionally safe — the
    /// pasteboard's own thread-safety story is "main thread only,"
    /// and tools run from the actor-isolated tool registry, so calls
    /// serialise.
    public let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        let text = pasteboard.string(forType: .string) ?? ""
        return ToolResult(output: text)
    }
}

/// Replace the clipboard's contents with the supplied string. Lets an
/// agent put a result on the user's clipboard ("put the rendered path
/// on my clipboard", "copy this snippet for me"). Returns a short
/// confirmation including the byte count so the model can quote it
/// back without re-emitting the original text.
///
/// Argument schema: `{"text": "<contents to place on the clipboard>"}`.
public struct ClipboardSetTool: BuiltinTool, @unchecked Sendable {
    public let name: ToolName = "clipboard.set"

    /// Cap on bytes the tool will write. The pasteboard itself can
    /// hold much more, but a runaway agent shouldn't put a megabyte
    /// of text on the user's clipboard without warning. 64 KB matches
    /// `fs.read`'s cap so the round-tripping pattern (read a file,
    /// put on clipboard) is symmetric.
    public static let maxBytes = 64 * 1024

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Replace the macOS clipboard's contents with text. Arguments: {\"text\": \"<contents>\"}. Returns a short confirmation. Maximum content size: \(Self.maxBytes) bytes."
        )
    }

    public let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    private struct Args: Decodable {
        let text: String
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        guard let data = arguments.data(using: .utf8) else {
            return ToolResult(output: "", error: "arguments not UTF-8")
        }
        let parsed: Args
        do {
            parsed = try JSONDecoder().decode(Args.self, from: data)
        } catch {
            return ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)")
        }
        let bytes = parsed.text.utf8.count
        guard bytes <= Self.maxBytes else {
            return ToolResult(output: "", error: "text exceeds \(Self.maxBytes)-byte cap (\(bytes) bytes provided)")
        }
        // `clearContents()` is the documented way to invalidate the
        // pasteboard's existing change-count and prepare it for a
        // fresh write; without it `setString` returns true but old
        // representations (RTF, file URL) can survive alongside the
        // new string and confuse paste targets.
        pasteboard.clearContents()
        let ok = pasteboard.setString(parsed.text, forType: .string)
        guard ok else {
            return ToolResult(output: "", error: "pasteboard write failed")
        }
        return ToolResult(output: "wrote \(bytes) bytes to clipboard")
    }
}
