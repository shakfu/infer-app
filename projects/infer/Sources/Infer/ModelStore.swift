import Foundation

enum ModelStore {
    /// Default directory for .gguf models when the user has not configured a
    /// custom path. Creates the directory on first access.
    static func defaultGGUFDirectory() -> URL {
        let fm = FileManager.default
        let base: URL
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            base = appSupport.appendingPathComponent("Infer", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/Infer/Models", isDirectory: true)
        }
        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    /// Resolve the effective GGUF directory. Empty setting => default.
    static func resolvedGGUFDirectory(setting: String) -> URL {
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultGGUFDirectory() }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// True if the .gguf file at `path` exists and is a regular file.
    static func llamaArtifactExists(path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    /// Root of the Hugging Face hub cache. Honors `HF_HOME`; defaults to
    /// `~/.cache/huggingface/hub`.
    static func hfHubRoot() -> URL {
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: (hfHome as NSString).expandingTildeInPath)
                .appendingPathComponent("hub", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// Scan the HF hub cache for `models--*` directories with at least one
    /// non-empty snapshot. Returns HF ids in the original `org/repo` form.
    static func scanMLXCache() -> [String] {
        let fm = FileManager.default
        let root = hfHubRoot()
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var ids: [String] = []
        for name in entries where name.hasPrefix("models--") {
            let snapshots = root
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("snapshots", isDirectory: true)
            let children = (try? fm.contentsOfDirectory(atPath: snapshots.path)) ?? []
            guard !children.isEmpty else { continue }
            let stripped = String(name.dropFirst("models--".count))
            // HF encodes org/repo as "org--repo". Split on the first "--".
            if let range = stripped.range(of: "--") {
                let org = stripped[..<range.lowerBound]
                let repo = stripped[range.upperBound...]
                ids.append("\(org)/\(repo)")
            } else {
                ids.append(stripped)
            }
        }
        return ids
    }

    /// Scan `dir` (non-recursive) for `.gguf` files, returning absolute paths.
    static func scanGGUFDirectory(_ dir: URL) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .map { $0.path }
    }

    /// True if an MLX model's weights are resolvable in the HF cache.
    /// Checks `$HF_HOME/hub/models--<sanitized-id>/snapshots/` for at least
    /// one non-empty snapshot directory. Does not validate file integrity.
    static func mlxArtifactExists(hfId: String) -> Bool {
        guard !hfId.isEmpty else { return false }
        let sanitized = hfId.replacingOccurrences(of: "/", with: "--")
        let snapshots = hfHubRoot()
            .appendingPathComponent("models--\(sanitized)", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: snapshots.path) else {
            return false
        }
        return !entries.isEmpty
    }
}

enum GGUFDownloadError: Error, LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case filesystem(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Not a valid download URL"
        case .httpStatus(let code): return "Download failed with HTTP \(code)"
        case .filesystem(let msg): return "Filesystem error: \(msg)"
        }
    }
}

/// Streams a remote .gguf to disk with progress reporting. URLSession download
/// task is used for its native resume-tempfile semantics; we move the result
/// into `destinationDir` with a filename derived from the URL (collisions are
/// disambiguated with a `-N` suffix). Cancellation is cooperative via
/// `Task.cancel()` — the underlying download task is cancelled in response.
actor GGUFDownloader {
    func download(
        url: URL,
        destinationDir: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationDir.path) {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }

        let (tempURL, response) = try await URLSession.shared.download(
            from: url,
            delegate: ProgressDelegate(callback: progress)
        )
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? fm.removeItem(at: tempURL)
            throw GGUFDownloadError.httpStatus(http.statusCode)
        }

        let filename = Self.filename(from: url, response: response)
        let target = Self.uniqueDestination(dir: destinationDir, filename: filename)
        do {
            try fm.moveItem(at: tempURL, to: target)
        } catch {
            throw GGUFDownloadError.filesystem(error.localizedDescription)
        }
        return target
    }

    private static func filename(from url: URL, response: URLResponse) -> String {
        // Prefer Content-Disposition if present; fall back to the URL's last
        // path component. Ensures `.gguf` suffix for clarity.
        if let http = response as? HTTPURLResponse,
           let disp = http.value(forHTTPHeaderField: "Content-Disposition"),
           let name = Self.extractFilename(from: disp) {
            return Self.ensureGGUF(name)
        }
        let last = url.lastPathComponent
        return Self.ensureGGUF(last.isEmpty ? "model.gguf" : last)
    }

    private static func extractFilename(from contentDisposition: String) -> String? {
        // Minimal parser: filename="..." or filename=...
        let parts = contentDisposition.components(separatedBy: ";")
        for raw in parts {
            let piece = raw.trimmingCharacters(in: .whitespaces)
            if piece.lowercased().hasPrefix("filename=") {
                var value = String(piece.dropFirst("filename=".count))
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func ensureGGUF(_ name: String) -> String {
        name.lowercased().hasSuffix(".gguf") ? name : name + ".gguf"
    }

    private static func uniqueDestination(dir: URL, filename: String) -> URL {
        let base = dir.appendingPathComponent(filename)
        let fm = FileManager.default
        if !fm.fileExists(atPath: base.path) { return base }
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = dir.appendingPathComponent("\(stem)-\(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let callback: @Sendable (Double) -> Void
    init(callback: @escaping @Sendable (Double) -> Void) {
        self.callback = callback
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        callback(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession.download(from:delegate:) handles the temp file plumbing;
        // this override is required for delegate conformance but intentionally
        // left empty.
    }
}
