import Foundation
import InferAgents
import PDFKit

/// Result of loading a file into plain text. Plus the kind tag that
/// ends up in `sources.kind`, which the UI can use to choose an icon
/// or render the source differently.
struct LoadedSource: Sendable {
    let kind: String        // "txt" | "md" | "json" | "pdf" | "url"
    let content: String
}

enum SourceLoaderError: Error, CustomStringConvertible {
    case unsupportedExtension(String)
    case readFailed(URL, underlying: Error)
    case notUTF8(URL)
    case empty(URL)
    case unreadablePDF(URL)
    case lockedPDF(URL)
    case noPDFText(URL)

    var description: String {
        switch self {
        case .unsupportedExtension(let ext):
            return "unsupported file extension '\(ext)' (txt, md, json, pdf accepted)"
        case .readFailed(let url, let err):
            return "failed to read \(url.lastPathComponent): \(err.localizedDescription)"
        case .notUTF8(let url):
            return "\(url.lastPathComponent) is not valid UTF-8"
        case .empty(let url):
            return "\(url.lastPathComponent) is empty"
        case .unreadablePDF(let url):
            return "\(url.lastPathComponent) could not be opened as a PDF"
        case .lockedPDF(let url):
            return "\(url.lastPathComponent) is password-protected"
        case .noPDFText(let url):
            return "\(url.lastPathComponent) has no text layer; it may be a scan"
        }
    }
}

/// File-extension → text content dispatch. Keeps the ingestion
/// orchestrator one call site rather than a switch statement.
///
/// PDF text comes from PDFKit, so column order can be wrong and scans fail.
enum SourceLoader {
    static let supportedExtensions: Set<String> = ["txt", "md", "json", "pdf"]

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
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { throw SourceLoaderError.unreadablePDF(url) }
            guard !document.isLocked else { throw SourceLoaderError.lockedPDF(url) }
            guard let text = pdfText(document) else { throw SourceLoaderError.noPDFText(url) }
            return LoadedSource(kind: "pdf", content: text)
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

    /// The text layer of every page, or nil when there is none.
    static func pdfText(_ document: PDFDocument) -> String? {
        let pages = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
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

enum RemoteSourceError: Error, CustomStringConvertible {
    case invalidURL
    case http(Int)
    case unsupportedContentType(String)
    case tooLarge(Int)
    case unreadablePDF
    case lockedPDF
    case noPDFText
    case empty

    var description: String {
        switch self {
        case .invalidURL: return "enter a full http or https URL"
        case .http(let status): return "the server returned HTTP \(status)"
        case .unsupportedContentType(let type): return "unsupported content type '\(type)' (text, JSON and PDF accepted)"
        case .tooLarge(let limit): return "the response exceeds \(limit) bytes"
        case .unreadablePDF: return "the response could not be opened as a PDF"
        case .lockedPDF: return "the PDF is password-protected"
        case .noPDFText: return "the PDF has no text layer; it may be a scan"
        case .empty: return "the response has no text"
        }
    }
}

/// Fetches a URL the user entered. No host allowlist: unlike `http.fetch`, a
/// person chooses every URL here.
enum RemoteSourceLoader {
    static let maxTextBytes = 10 * 1024 * 1024
    static let maxPDFBytes = 50 * 1024 * 1024

    /// Returns the source and a hash of the raw body.
    static func load(
        _ urlString: String,
        session: URLSession = .shared,
        textLimit: Int = maxTextBytes,
        pdfLimit: Int = maxPDFBytes
    ) async throws -> (LoadedSource, String) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false
        else { throw RemoteSourceError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (stream, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RemoteSourceError.http(http.statusCode)
        }
        let mime = (response.mimeType ?? "").lowercased()
        let isPDF = mime == "application/pdf"
        let isHTML = mime == "text/html" || mime == "application/xhtml+xml"
        guard isPDF || isHTML || mime.hasPrefix("text/") || mime == "application/json" || mime.hasSuffix("+json") else {
            throw RemoteSourceError.unsupportedContentType(mime.isEmpty ? "unknown" : mime)
        }

        // Check the declared length, then the running count, because a server
        // can omit the header or understate it.
        let limit = isPDF ? pdfLimit : textLimit
        guard response.expectedContentLength <= Int64(limit) else { throw RemoteSourceError.tooLarge(limit) }
        var body = Data()
        for try await byte in stream {
            body.append(byte)
            guard body.count <= limit else { throw RemoteSourceError.tooLarge(limit) }
        }

        let hash = SourceLoader.contentHash(of: body)
        if isPDF {
            guard let document = PDFDocument(data: body) else { throw RemoteSourceError.unreadablePDF }
            guard !document.isLocked else { throw RemoteSourceError.lockedPDF }
            guard let text = SourceLoader.pdfText(document) else { throw RemoteSourceError.noPDFText }
            return (LoadedSource(kind: "url", content: text), hash)
        }
        let raw = decode(body, declaredCharset: response.textEncodingName, isHTML: isHTML)
        let content = isHTML ? htmlToPlainText(raw) : raw
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteSourceError.empty
        }
        return (LoadedSource(kind: "url", content: content), hash)
    }

    /// Tries the HTTP charset, UTF-8, an HTML `<meta>` charset, then Windows-1252,
    /// then Latin-1, which accepts any bytes.
    static func decode(_ body: Data, declaredCharset: String?, isHTML: Bool) -> String {
        if let encoding = declaredCharset.flatMap(encoding(named:)),
           let text = String(data: body, encoding: encoding) {
            return text
        }
        if let text = String(data: body, encoding: .utf8) { return text }
        if isHTML {
            let head = String(decoding: body.prefix(2048), as: Unicode.ASCII.self)
            if let match = head.range(of: #"(?i)charset\s*=\s*["']?[A-Za-z0-9_.:-]+"#, options: .regularExpression) {
                let name = head[match].split(whereSeparator: { "=\"' ".contains($0) }).last.map(String.init)
                if let encoding = name.flatMap(encoding(named:)), let text = String(data: body, encoding: encoding) {
                    return text
                }
            }
        }
        return String(data: body, encoding: .windowsCP1252) ?? String(data: body, encoding: .isoLatin1) ?? ""
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
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
