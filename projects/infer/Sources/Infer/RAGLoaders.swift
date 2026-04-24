import Foundation

/// Result of loading a file into plain text. Plus the kind tag that
/// ends up in `sources.kind`, which the UI can use to choose an icon
/// or render the source differently.
struct LoadedSource {
    let kind: String        // "txt" | "md" | "json"
    let content: String
}

enum SourceLoaderError: Error, CustomStringConvertible {
    case unsupportedExtension(String)
    case readFailed(URL, underlying: Error)
    case notUTF8(URL)
    case empty(URL)

    var description: String {
        switch self {
        case .unsupportedExtension(let ext):
            return "unsupported file extension '\(ext)' (txt, md, json accepted)"
        case .readFailed(let url, let err):
            return "failed to read \(url.lastPathComponent): \(err.localizedDescription)"
        case .notUTF8(let url):
            return "\(url.lastPathComponent) is not valid UTF-8"
        case .empty(let url):
            return "\(url.lastPathComponent) is empty"
        }
    }
}

/// File-extension → text content dispatch. Keeps the ingestion
/// orchestrator one call site rather than a switch statement.
///
/// Supported formats in MVP: `.txt`, `.md`, `.json`. PDF support is
/// deferred — Apple's PDFKit text extraction works but quality varies
/// a lot by source, and shipping a half-quality path is worse than
/// making users convert to markdown themselves for now.
enum SourceLoader {
    static let supportedExtensions: Set<String> = ["txt", "md", "json"]

    /// True if this file is eligible for ingestion. Cheap — a string
    /// extension check, no I/O. Called from the folder scanner to
    /// filter candidates before hashing + loading.
    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Load `url` as UTF-8 text and tag it with its kind. Throws for
    /// unsupported extensions, unreadable files, or non-UTF-8 content.
    /// Empty files throw `.empty` so the caller can skip them without
    /// polluting the vector store with zero-chunk sources.
    static func load(_ url: URL) throws -> LoadedSource {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw SourceLoaderError.unsupportedExtension(ext)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SourceLoaderError.readFailed(url, underlying: error)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw SourceLoaderError.notUTF8(url)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SourceLoaderError.empty(url)
        }
        return LoadedSource(kind: ext, content: content)
    }

    /// Stable dedup hash over the raw file bytes (not the decoded
    /// text — same bytes = same hash even if encoding heuristics
    /// differ). MD5 is fine here: this is a content identity check,
    /// not a security-sensitive digest.
    static func contentHash(of data: Data) -> String {
        // Use CommonCrypto-free MD5 via Foundation's Insecure.MD5.
        // Good enough for dedup; collisions on file content are a
        // cosmetic annoyance, not a safety issue.
        let digest = Insecure_MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// Tiny MD5 shim — avoids pulling in CryptoKit's Crypto module in
// files that don't already import it. Using Crypto.Insecure.MD5
// directly is preferred when available; this wrapper exists so the
// single call site stays clean.
//
// Swift's CryptoKit is always available on macOS 10.15+.
import CryptoKit

private enum Insecure_MD5 {
    static func hash(data: Data) -> [UInt8] {
        Array(Insecure.MD5.hash(data: data))
    }
}
