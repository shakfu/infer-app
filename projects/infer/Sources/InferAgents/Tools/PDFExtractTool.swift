import Foundation
import PDFKit

/// Sandboxed PDF text extraction. Opens a local `.pdf`, walks selected
/// pages via `PDFKit`, and returns the text layer with `--- Page N ---`
/// separators so the model can cite by page number.
///
/// What this is NOT:
/// - An OCR tool. Image-only PDFs (scanned without a text layer) return
///   an empty string per page; the tool surfaces a hint in that case so
///   the model doesn't claim it read the document. Real OCR would need
///   `Vision`'s `VNRecognizeTextRequest` and is a separate decision.
/// - Layout-preserving. PDFKit's `string` accessor returns the text in
///   reading order as best PDFKit can infer; multi-column papers and
///   tables come out in the order the producer wrote glyphs. For most
///   use cases (asking the model about a doc) this is fine; for
///   structured extraction, more work is needed.
///
/// Argument schema:
/// ```
/// {
///   "path": "/absolute/or/~-relative/path.pdf",
///   "pageRange": "1-5"        // optional; "1,3,5" / "all" / "3" also valid
/// }
/// ```
///
/// Output is capped at `maxBytes` (truncated with a marker beyond that)
/// so a 500-page PDF can't blow the model's context window in one call.
/// The model can re-call with a narrower `pageRange` if it needs more.
public struct PDFExtractTool: BuiltinTool {
    public let name: ToolName = "pdf.extract"

    /// Hard cap on returned bytes. Larger than `fs.read`'s 64 KB
    /// because PDFs are content-heavy on purpose — the user is calling
    /// this to feed real document text to the model — but still bounded
    /// to keep one tool call from monopolising the context window.
    /// Tune up if reasoning models with bigger contexts (Qwen3-32B,
    /// Llama-3.1-405B) become the common case.
    public static let maxBytes = 256 * 1024

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Extract the text layer from a local PDF. Arguments: \
                {"path": "<absolute or ~/-relative path to the .pdf>", \
                "pageRange": "1-5"}. \
                `pageRange` is optional and accepts a single page (`"3"`), \
                an inclusive range (`"1-5"`), a comma-separated mix \
                (`"1,3,5-7"`), or `"all"` (the default). Pages are \
                1-indexed. Returns the text content with `--- Page N ---` \
                separators between pages. Image-only / scanned PDFs \
                return a hint that no text layer is present — call \
                another tool or ask the user to OCR first. Output is \
                capped at \(Self.maxBytes) bytes; truncated PDFs end with \
                a marker so the model knows to re-call with a narrower \
                page range. The PDF must live under one of the host's \
                allowed roots; reads outside the sandbox return an error.
                """
        )
    }

    /// Allowed-roots sandbox, same shape as `FilesystemReadTool`. Empty
    /// = deny everything (tool stays registered but refuses every call
    /// until the host configures it).
    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private struct Args: Decodable {
        let path: String
        let pageRange: String?
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

        // Sandbox check — same logic as FilesystemReadTool, deliberately
        // kept inline rather than factored into a shared helper because
        // the two tools have slightly different error wording and
        // tightening either's check shouldn't loosen the other.
        let expanded = (parsed.path as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !allowedRoots.isEmpty else {
            return ToolResult(output: "", error: "pdf.extract is not configured: no allowed roots")
        }
        let allowed = allowedRoots.contains { root in
            candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
        }
        guard allowed else {
            return ToolResult(output: "", error: "path is outside the allowed sandbox")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return ToolResult(output: "", error: "no such file: \(parsed.path)")
        }
        if isDirectory.boolValue {
            return ToolResult(output: "", error: "path is a directory, not a file")
        }

        guard let document = PDFDocument(url: candidate) else {
            // PDFKit returns nil for non-PDFs and for encrypted PDFs
            // (without the password). Lump them together — the model's
            // recovery is the same either way (ask the user / pick a
            // different file).
            return ToolResult(output: "", error: "could not open as PDF (corrupt, encrypted, or not a PDF file)")
        }
        let totalPages = document.pageCount
        guard totalPages > 0 else {
            return ToolResult(output: "", error: "PDF has zero pages")
        }

        let pageIndices: [Int]
        switch Self.parsePageRange(parsed.pageRange, totalPages: totalPages) {
        case .ok(let indices):
            pageIndices = indices
        case .invalid(let message):
            return ToolResult(output: "", error: message)
        }
        guard !pageIndices.isEmpty else {
            return ToolResult(output: "", error: "page range '\(parsed.pageRange ?? "")' selected no pages (PDF has \(totalPages) page\(totalPages == 1 ? "" : "s"))")
        }

        var assembled = ""
        var truncated = false
        var emptyCount = 0
        for index in pageIndices {
            guard let page = document.page(at: index) else { continue }
            let pageText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if pageText.isEmpty { emptyCount += 1 }

            // 1-indexed in the marker so the model's citations match
            // what the user sees in Preview / a PDF reader.
            let header = "\n\n--- Page \(index + 1) ---\n\n"
            let chunk = header + pageText
            if assembled.utf8.count + chunk.utf8.count > Self.maxBytes {
                let remaining = Self.maxBytes - assembled.utf8.count
                if remaining > 0 {
                    // Append as much as fits. Slicing on UTF-8 byte count
                    // is awkward in Swift; conservative path is to take
                    // a character prefix and check.
                    var prefixChars = chunk
                    while prefixChars.utf8.count > remaining {
                        prefixChars.removeLast()
                    }
                    assembled.append(prefixChars)
                }
                truncated = true
                break
            }
            assembled.append(chunk)
        }

        if truncated {
            assembled.append("\n\n[... truncated at \(Self.maxBytes) bytes; re-call with a narrower pageRange ...]")
        }
        let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)

        // Image-only PDF heuristic: every selected page returned empty.
        // Don't refuse — a partial extraction (e.g. a scanned PDF with
        // one accidentally-text-layer'd page) is still useful — but
        // prefix a hint so the model doesn't pretend it read the doc.
        if trimmed.isEmpty || (emptyCount == pageIndices.count) {
            return ToolResult(
                output: "",
                error: "the selected page\(pageIndices.count == 1 ? "" : "s") of this PDF contain\(pageIndices.count == 1 ? "s" : "") no extractable text — likely a scanned / image-only PDF. OCR is required."
            )
        }
        return ToolResult(output: trimmed)
    }

    /// Result of `parsePageRange`. A two-case enum rather than `Result`
    /// because the failure side carries a user-facing message string —
    /// `Result<_, String>` would require `String: Error`, which it
    /// isn't, and a wrapper error type just to satisfy that constraint
    /// is more ceremony than the call site benefits from.
    enum PageRangeOutcome: Equatable {
        case ok([Int])
        case invalid(String)
    }

    /// Parse a user-facing page-range string into a sorted, deduplicated
    /// list of 0-indexed page indices, clamped to `[0, totalPages)`.
    /// Returns an error message for syntactically invalid input rather
    /// than silently producing an empty result, so the model's recovery
    /// is to fix the syntax rather than guess at why nothing came back.
    static func parsePageRange(_ raw: String?, totalPages: Int) -> PageRangeOutcome {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "all" {
            return .ok(Array(0..<totalPages))
        }
        var pages = Set<Int>()
        for chunk in trimmed.split(separator: ",") {
            let part = chunk.trimmingCharacters(in: .whitespaces)
            if part.contains("-") {
                let bits = part.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard bits.count == 2,
                      let lo = Int(bits[0]),
                      let hi = Int(bits[1]),
                      lo >= 1, hi >= lo else {
                    return .invalid("invalid page range '\(part)' — expected 'N-M' with 1 <= N <= M")
                }
                for p in lo...hi where p <= totalPages {
                    pages.insert(p - 1)
                }
            } else if let n = Int(part) {
                guard n >= 1 else {
                    return .invalid("invalid page '\(part)' — pages are 1-indexed")
                }
                if n <= totalPages { pages.insert(n - 1) }
            } else {
                return .invalid("could not parse '\(part)' as a page number or range")
            }
        }
        return .ok(pages.sorted())
    }
}
