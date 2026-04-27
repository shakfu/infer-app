import Foundation

/// Returns the current time as an ISO-8601 string. Zero arguments.
///
/// The simplest possible tool — useful for verifying the loop runs at
/// all (round-trip: model emits a tool call, we produce a real-world
/// value the model couldn't know otherwise, model incorporates it).
public struct ClockNowTool: BuiltinTool {
    public let name: ToolName = "builtin.clock.now"

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Returns the current date and time as an ISO 8601 string (UTC). Call with an empty parameters object: {}."
        )
    }

    /// Hook for tests to pin the clock. Nil = real time.
    let fixedDate: Date?

    public init(fixedDate: Date? = nil) {
        self.fixedDate = fixedDate
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = fixedDate ?? Date()
        return ToolResult(output: formatter.string(from: now))
    }
}

/// Synthetic dispatch tool used by orchestrator agents (M5c).
///
/// The router agent emits a tool call to `agents.invoke` whose arguments
/// name the candidate to dispatch to and the input to hand it. The tool
/// itself is **inert** — it returns a short acknowledgement so the
/// runtime tool loop has something to feed back as ipython/tool input
/// and the router can produce a closing turn. The actual cross-agent
/// dispatch happens *after* the router's segment completes:
/// `CompositionController.runOrchestrator` reads the trace, sees this
/// tool call (via `OrchestratorDispatch.parse`), and runs the chosen
/// candidate as a follow-on segment.
///
/// The two-step design (call here, dispatch in the controller) keeps
/// the tool stateless and stateless-tool-registerable — `BuiltinTool`
/// has no per-call composition context, and we don't want one. Routers
/// must include `agents.invoke` in their `toolsAllow`; the candidate
/// list itself is enumerated in the router agent's authored system
/// prompt so the model knows which targets are valid.
/// Structured handoff dispatch tool. Replaces the free-text
/// `<<HANDOFF target="…">>` … `<<END_HANDOFF>>` envelope with a real
/// tool call: an agent that wants to delegate emits
/// `agents.handoff` with `{"target": "<peer id>", "payload": "<message>"}`,
/// and the composition driver follows it the same way it follows the
/// envelope today. Like `agents.invoke`, this tool is **inert** — it
/// only acks so the runtime tool loop has something to feed back; the
/// actual cross-agent dispatch is done by the loop driver after the
/// segment completes by inspecting the trace for this call (see
/// `HandoffDispatch.parse`).
///
/// The free-text envelope (`HandoffEnvelope.parse`) remains a fallback
/// path so older agent configs keep working; the structured route wins
/// when both are present in the same turn.
public struct AgentsHandoffTool: BuiltinTool {
    public let name: ToolName = "agents.handoff"

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Hand off the current turn to a peer agent. Arguments: {\"target\": \"<peer agent id>\", \"payload\": \"<message to pass\"}. The composition driver dispatches the named target with the payload as its user turn; the target's reply replaces yours as the user-visible answer."
        )
    }

    public init() {}

    public func invoke(arguments: String) async throws -> ToolResult {
        ToolResult(output: "handoff acknowledged")
    }
}

public struct AgentsInvokeTool: BuiltinTool {
    public let name: ToolName = "agents.invoke"

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Dispatch a follow-up turn to one of the candidate agents listed in your system prompt. Arguments: {\"agentID\": \"<candidate id>\", \"input\": \"<the message to send the candidate>\"}. The candidate's reply replaces yours as the user-visible answer."
        )
    }

    public init() {}

    public func invoke(arguments: String) async throws -> ToolResult {
        // Inert: composition driver reads the call from the trace
        // post-segment and follows through with the actual dispatch.
        // The ack here is what the router sees as feedback so it can
        // close the turn cleanly; the user never sees this string
        // because the candidate's reply replaces the router's output.
        ToolResult(output: "dispatch acknowledged")
    }
}

/// Counts whitespace-separated tokens in a string passed as
/// `{"text": "..."}`. No network, no I/O. Useful as the second demo
/// tool because it exercises argument decoding (unlike `clock.now`).
public struct WordCountTool: BuiltinTool {
    public let name: ToolName = "builtin.text.wordcount"

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Counts whitespace-separated words in a passage of text. Arguments: {\"text\": \"<the passage>\"}. Returns the count as a decimal integer."
        )
    }

    public init() {}

    private struct Args: Decodable {
        let text: String
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        guard let data = arguments.data(using: .utf8) else {
            return ToolResult(output: "", error: "arguments not UTF-8")
        }
        do {
            let parsed = try JSONDecoder().decode(Args.self, from: data)
            let count = parsed.text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .count
            return ToolResult(output: String(count))
        } catch {
            return ToolResult(
                output: "",
                error: "could not parse arguments: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Real tools

/// Sandboxed file read. Refuses any path that does not resolve under
/// one of `allowedRoots`, refuses symlinks that escape after resolution,
/// and caps the byte count returned. The read happens off the current
/// actor via `Data(contentsOf:)` — fine for a builtin since the tool
/// loop is already async; large files are truncated rather than
/// streamed (the model can't usefully consume megabytes in one turn).
///
/// Argument schema: `{"path": "/absolute/or/~-relative/path"}`. Tilde
/// expansion is handled here so the model can pass user-friendly paths;
/// the post-expansion path is what's checked against `allowedRoots`.
public struct FilesystemReadTool: BuiltinTool {
    public let name: ToolName = "fs.read"

    /// Hard cap on bytes returned per call. Files longer than this are
    /// truncated and a marker is appended. Keeps the model's context
    /// from being blown out by a single large file.
    public static let maxBytes = 64 * 1024

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Read a UTF-8 text file from disk. Arguments: {\"path\": \"<absolute or ~/-relative path>\"}. The file must live under an allowed root; reads of files outside the sandbox return an error. Returns up to \(Self.maxBytes) bytes; longer files are truncated."
        )
    }

    /// Absolute, fully-resolved directory URLs the tool will read
    /// under. An empty array means "deny everything" — the tool stays
    /// registered but refuses every call until the host configures it.
    /// Using `URL` (not `String`) so the host's resolution semantics
    /// (e.g. realpath) are baked into construction, not re-derived
    /// every invoke.
    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private struct Args: Decodable {
        let path: String
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
        // Tilde expansion + standardisation + symlink resolution must
        // all happen before the allowlist check, otherwise a symlink
        // inside an allowed root could escape it.
        let expanded = (parsed.path as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !allowedRoots.isEmpty else {
            return ToolResult(output: "", error: "fs.read is not configured: no allowed roots")
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
        do {
            let raw = try Data(contentsOf: candidate)
            let truncated = raw.count > Self.maxBytes
            let slice = truncated ? raw.prefix(Self.maxBytes) : raw
            guard let text = String(data: slice, encoding: .utf8) else {
                return ToolResult(output: "", error: "file is not valid UTF-8")
            }
            let suffix = truncated ? "\n\n[... truncated at \(Self.maxBytes) bytes ...]" : ""
            return ToolResult(output: text + suffix)
        } catch {
            return ToolResult(output: "", error: "read failed: \(error.localizedDescription)")
        }
    }
}

/// Vault / vector-store retrieval tool. The actual lookup is delegated
/// to a host-supplied `Retriever` closure (see `AgentContext`), so the
/// tool stays free of `InferRAG` / SQLite / embedding concerns. The
/// host wires the closure at registration time, typically by closing
/// over `VectorStore.search` plus an embedding step.
///
/// Argument schema: `{"query": "<text>", "topK": 5}`. `topK` is
/// optional and clamped to `[1, maxTopK]` so the model can't degrade
/// the turn by asking for hundreds of chunks.
public struct VaultSearchTool: BuiltinTool {
    public let name: ToolName = "vault.search"

    public static let defaultTopK = 5
    public static let maxTopK = 20

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Search the user's local document corpus (vault) for chunks relevant to a query. Arguments: {\"query\": \"<natural-language query>\", \"topK\": \(Self.defaultTopK)}. `topK` is optional (default \(Self.defaultTopK), max \(Self.maxTopK)). Returns a JSON array of {sourceURI, content, score} objects ordered by descending relevance, or an empty array when no corpus is configured."
        )
    }

    /// Host-supplied closure. Nil-equivalent (a tool registered with no
    /// retriever) returns an empty result rather than erroring — agents
    /// that always include `vault.search` in `toolsAllow` should still
    /// work on installs without a corpus.
    public let retriever: Retriever?

    public init(retriever: Retriever?) {
        self.retriever = retriever
    }

    private struct Args: Decodable {
        let query: String
        let topK: Int?
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
        let query = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolResult(output: "", error: "query is empty")
        }
        let k = max(1, min(Self.maxTopK, parsed.topK ?? Self.defaultTopK))
        guard let retriever else {
            return ToolResult(output: "[]")
        }
        do {
            let chunks = try await retriever(query, k)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(chunks)
            return ToolResult(output: String(decoding: payload, as: UTF8.self))
        } catch {
            return ToolResult(output: "", error: "retrieval failed: \(error.localizedDescription)")
        }
    }
}

/// HTTP GET fetcher with a strict host allowlist. Refuses non-HTTPS
/// schemes, hosts not on `allowedHosts`, redirects that leave the
/// allowlist, and bodies larger than `maxBytes`. The 60-second timeout
/// keeps a slow upstream from stalling the agent loop indefinitely.
///
/// Argument schema: `{"url": "https://host/path"}`. The tool returns
/// the response body as a UTF-8 string with content-type prepended on
/// the first line so the model can decide whether to parse JSON / HTML
/// / plain text.
public struct URLFetchTool: BuiltinTool, @unchecked Sendable {
    public let name: ToolName = "http.fetch"

    public static let maxBytes = 256 * 1024

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Fetch a URL over HTTPS GET. Arguments: {\"url\": \"https://<host>/<path>\"}. The host must be on the agent's allowlist; non-HTTPS URLs and oversize bodies are rejected. The first line of the result is `Content-Type: <mime>`; the rest is the response body, truncated at \(Self.maxBytes) bytes."
        )
    }

    public let allowedHosts: Set<String>
    /// Test seam: defaults to `URLSession.shared`. Tests inject a stub
    /// to avoid real network. `URLSession` is `Sendable` on Apple
    /// platforms; the `@unchecked Sendable` on the tool struct
    /// accommodates older Swift toolchains where it isn't.
    public let session: URLSession

    public init(allowedHosts: Set<String>, session: URLSession = .shared) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.session = session
    }

    private struct Args: Decodable {
        let url: String
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
        guard let url = URL(string: parsed.url) else {
            return ToolResult(output: "", error: "invalid URL")
        }
        guard url.scheme?.lowercased() == "https" else {
            return ToolResult(output: "", error: "only https URLs are allowed")
        }
        guard let host = url.host?.lowercased() else {
            return ToolResult(output: "", error: "URL has no host")
        }
        guard allowedHosts.contains(host) else {
            return ToolResult(output: "", error: "host '\(host)' is not on the allowlist")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("Infer/agents", forHTTPHeaderField: "User-Agent")
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ToolResult(output: "", error: "non-HTTP response")
            }
            // If the system followed a redirect, the final URL might
            // have left the allowlist. Re-check.
            if let finalHost = http.url?.host?.lowercased(),
               !allowedHosts.contains(finalHost) {
                return ToolResult(output: "", error: "redirect target '\(finalHost)' is not on the allowlist")
            }
            guard (200..<300).contains(http.statusCode) else {
                return ToolResult(output: "", error: "HTTP \(http.statusCode)")
            }
            let truncated = body.count > Self.maxBytes
            let slice = truncated ? body.prefix(Self.maxBytes) : body
            guard let text = String(data: slice, encoding: .utf8) else {
                return ToolResult(output: "", error: "response body is not valid UTF-8")
            }
            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
            let suffix = truncated ? "\n\n[... truncated at \(Self.maxBytes) bytes ...]" : ""
            return ToolResult(output: "Content-Type: \(mime)\n\n\(text)\(suffix)")
        } catch {
            return ToolResult(output: "", error: "fetch failed: \(error.localizedDescription)")
        }
    }
}

/// Sandboxed file write. Mirror of `FilesystemReadTool`: refuses paths
/// outside `allowedRoots`, refuses to overwrite existing files unless
/// `overwrite: true` is passed (defensive default — accidental clobbers
/// of a user's notes are exactly the failure mode worth one extra arg
/// to avoid), and refuses to create parent directories. Atomic write
/// via `Data.write(to:options:.atomic)` — content lands in a sibling
/// temp file first and is renamed onto the target, so a partial write
/// can't leave a half-written file under the user's eyes.
///
/// Argument schema:
/// ```
/// {
///   "path":      "/absolute/or/~-relative/path.txt",
///   "content":   "<UTF-8 string>",
///   "overwrite": false   // optional, default false
/// }
/// ```
///
/// Caps content at `maxBytes`. Returns "wrote N bytes to <path>" on
/// success so the model can confirm the operation completed and cite
/// the path back to the user.
public struct FilesystemWriteTool: BuiltinTool {
    public let name: ToolName = "fs.write"

    /// Hard cap on bytes written per call. 1 MB is generous for the
    /// "save the .qmd source the agent just generated" / "save an
    /// analysis" use cases without letting one stray tool call fill a
    /// disk. Tune up if a real workflow demands it.
    public static let maxBytes = 1024 * 1024

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Write a UTF-8 text file. Arguments: {\"path\": \"<absolute or ~/-relative path>\", \"content\": \"<text>\", \"overwrite\": false}. The path must live under an allowed root; writes outside the sandbox return an error. Refuses to overwrite an existing file unless `overwrite: true` is passed. Will not create parent directories — the parent must already exist. Maximum content size: \(Self.maxBytes) bytes."
        )
    }

    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private struct Args: Decodable {
        let path: String
        let content: String
        let overwrite: Bool?
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
        guard let payload = parsed.content.data(using: .utf8) else {
            return ToolResult(output: "", error: "content is not valid UTF-8")
        }
        guard payload.count <= Self.maxBytes else {
            return ToolResult(output: "", error: "content exceeds \(Self.maxBytes)-byte cap (\(payload.count) bytes provided)")
        }

        // Resolution must happen before the allowlist check so a symlink
        // inside an allowed root can't escape it. Mirror of fs.read.
        let expanded = (parsed.path as NSString).expandingTildeInPath
        // Don't `resolvingSymlinksInPath()` on a path that doesn't exist
        // yet — that returns the input unchanged, which is fine, but
        // resolving the parent first lets us check the real parent
        // directory against the sandbox.
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        let resolvedParent = candidate
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let resolvedTarget = resolvedParent.appendingPathComponent(candidate.lastPathComponent)

        guard !allowedRoots.isEmpty else {
            return ToolResult(output: "", error: "fs.write is not configured: no allowed roots")
        }
        let allowed = allowedRoots.contains { root in
            resolvedTarget.path == root.path || resolvedTarget.path.hasPrefix(root.path + "/")
        }
        guard allowed else {
            return ToolResult(output: "", error: "path is outside the allowed sandbox")
        }

        // Refuse to write to a path that's currently a directory.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolvedTarget.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            return ToolResult(output: "", error: "path is a directory, not a file")
        }
        if exists && !(parsed.overwrite ?? false) {
            return ToolResult(output: "", error: "file exists; pass `\"overwrite\": true` to replace it")
        }
        // Parent directory must exist — we don't auto-mkdir because
        // typo'd subdirs ("Documents/notes/draft.qmd" vs "documents/...")
        // would silently create a wrong-cased path.
        var parentIsDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedParent.path, isDirectory: &parentIsDir),
              parentIsDir.boolValue else {
            return ToolResult(output: "", error: "parent directory does not exist: \(resolvedParent.path)")
        }

        do {
            try payload.write(to: resolvedTarget, options: [.atomic])
        } catch {
            return ToolResult(output: "", error: "write failed: \(error.localizedDescription)")
        }
        return ToolResult(output: "wrote \(payload.count) bytes to \(resolvedTarget.path)")
    }
}

/// Sandboxed directory listing. Returns a JSON array of entries, each
/// `{path, name, isDirectory, size}`. Bounded by `maxEntries` and
/// `maxDepth` to keep one tool call from dumping a million-file
/// directory into the model's context. Hides dotfiles by default —
/// `.git`, `.DS_Store`, etc. are noise for the typical "list the
/// markdown notes" prompt.
///
/// Argument schema:
/// ```
/// {
///   "path":          "/absolute/or/~-relative/dir",
///   "recursive":     false,           // optional, default false
///   "extensions":    ["md", "qmd"],   // optional, case-insensitive,
///                                     //   leading "." optional;
///                                     //   filters files only — dirs
///                                     //   pass through regardless
///   "includeHidden": false            // optional, default false
/// }
/// ```
public struct FilesystemListTool: BuiltinTool {
    public let name: ToolName = "fs.list"

    public static let maxEntries = 200
    public static let maxDepth = 4

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "List the contents of a directory. Arguments: {\"path\": \"<absolute or ~/-relative dir>\", \"recursive\": false, \"extensions\": [\"md\", \"qmd\"], \"includeHidden\": false}. Returns a JSON array of entries `{path, name, isDirectory, size}`. The directory must live under an allowed root. Capped at \(Self.maxEntries) entries (when truncated, the array ends with a single `{\"truncated\": true}` element); recursion is bounded at depth \(Self.maxDepth). The `extensions` filter applies to files only and accepts forms with or without a leading dot."
        )
    }

    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private struct Args: Decodable {
        let path: String
        let recursive: Bool?
        let extensions: [String]?
        let includeHidden: Bool?
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
        let expanded = (parsed.path as NSString).expandingTildeInPath
        let root = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !allowedRoots.isEmpty else {
            return ToolResult(output: "", error: "fs.list is not configured: no allowed roots")
        }
        let allowed = allowedRoots.contains { allowedRoot in
            root.path == allowedRoot.path || root.path.hasPrefix(allowedRoot.path + "/")
        }
        guard allowed else {
            return ToolResult(output: "", error: "path is outside the allowed sandbox")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else {
            return ToolResult(output: "", error: "no such directory: \(parsed.path)")
        }
        guard isDir.boolValue else {
            return ToolResult(output: "", error: "path is a file, not a directory")
        }

        let filter = (parsed.extensions ?? []).map {
            $0.hasPrefix(".") ? String($0.dropFirst()).lowercased() : $0.lowercased()
        }
        let includeHidden = parsed.includeHidden ?? false
        let recursive = parsed.recursive ?? false

        var entries: [[String: Any]] = []
        var truncated = false
        Self.walk(
            root: root,
            recursive: recursive,
            currentDepth: 0,
            includeHidden: includeHidden,
            extensions: filter,
            entries: &entries,
            truncated: &truncated
        )

        if truncated {
            entries.append(["truncated": true])
        }

        do {
            let out = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
            return ToolResult(output: String(decoding: out, as: UTF8.self))
        } catch {
            return ToolResult(output: "", error: "could not encode listing: \(error.localizedDescription)")
        }
    }

    /// Recursive walk shared with the unit tests. Static + nonisolated
    /// so tests can call it directly to assert the depth / cap rules
    /// without spinning up a tool instance.
    static func walk(
        root: URL,
        recursive: Bool,
        currentDepth: Int,
        includeHidden: Bool,
        extensions: [String],
        entries: inout [[String: Any]],
        truncated: inout Bool
    ) {
        guard !truncated else { return }
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        // Stable order: name-sorted. `contentsOfDirectory` is FS-order
        // by default, which is unstable across runs and would make the
        // tool's output non-deterministic.
        let sorted = kids.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in sorted {
            if entries.count >= Self.maxEntries {
                truncated = true
                return
            }
            let name = url.lastPathComponent
            if !includeHidden, name.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false
            // Extension filter applies to files only. Directories pass
            // through so a recursive walk can descend into them.
            if !isDir, !extensions.isEmpty {
                let ext = url.pathExtension.lowercased()
                if !extensions.contains(ext) { continue }
            }
            var entry: [String: Any] = [
                "path": url.path,
                "name": name,
                "isDirectory": isDir,
            ]
            if !isDir, let size = values?.fileSize {
                entry["size"] = size
            }
            entries.append(entry)
            if isDir, recursive, currentDepth + 1 < Self.maxDepth {
                walk(
                    root: url,
                    recursive: true,
                    currentDepth: currentDepth + 1,
                    includeHidden: includeHidden,
                    extensions: extensions,
                    entries: &entries,
                    truncated: &truncated
                )
                if truncated { return }
            }
        }
    }
}

/// Pure arithmetic evaluation backed by `NSExpression`. Models —
/// especially small ones — silently miscompute multi-step arithmetic
/// (`0.0825 * 12 * 30` is a common failure mode). One tool call gives
/// them a deterministic calculator.
///
/// `NSExpression` exposes a `FUNCTION:` form that can invoke arbitrary
/// Objective-C selectors at evaluation time — a real risk if the input
/// is attacker-controlled. We mitigate by validating the input against
/// a strict whitelist (digits, arithmetic operators, parens, dot, `e`/`E`
/// for scientific notation, whitespace) BEFORE handing it to
/// `NSExpression`. Anything outside the whitelist is rejected with a
/// descriptive error. The whitelist deliberately excludes letters, so
/// `FUNCTION` / `SELF` / variable references can't appear.
///
/// Argument schema: `{"expression": "0.0825 * 12 * 30"}`. Returns the
/// numeric result as a string (`Double` description, so `1234567.0` and
/// `2.5e-3` both round-trip readably).
public struct MathComputeTool: BuiltinTool {
    public let name: ToolName = "math.compute"

    /// Inputs are bounded — no realistic arithmetic prompt needs more
    /// than a few hundred characters, and the cap is what makes the
    /// regex check cheap to reason about. `NSExpression` itself has no
    /// upper bound; this is a defensive belt for the model.
    public static let maxLength = 256

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Evaluate an arithmetic expression. Arguments: {\"expression\": \"<expression>\"}. Supports `+`, `-`, `*`, `/`, parentheses, decimal numbers, and scientific notation (`1.5e-3`). Does NOT support named functions (sqrt, log, etc.) — anything containing letters is rejected. Returns the numeric result as a string."
        )
    }

    public init() {}

    private struct Args: Decodable {
        let expression: String
    }

    /// Whitelist used to reject anything that could trigger
    /// `NSExpression`'s `FUNCTION:` evaluation path. `e` and `E` are
    /// allowed for scientific-notation literals; the parser only treats
    /// them as exponent markers when sandwiched between digits, and any
    /// other use ("eat") would also be rejected as a syntax error by
    /// `NSExpression` — but the regex check rejects the input before
    /// `NSExpression` sees it, which is the load-bearing guarantee.
    static let whitelistRegex = try! NSRegularExpression(
        pattern: #"^[0-9eE+\-*/().,\s]+$"#
    )

    /// Matches a bare integer literal — a digit run with no decimal
    /// point / exponent neighbour on either side. Used to coerce
    /// integer literals to doubles before evaluation, so `1 / 3`
    /// returns `0.333…` instead of integer-division `0`. Modern
    /// calculators don't surprise users with integer division and
    /// `NSExpression` has no flag to switch it off; pre-rewriting the
    /// input is the simplest fix that keeps the rest of the tool
    /// pure-`NSExpression`. Skips digit runs that are part of a
    /// decimal (`1.5`) or scientific-notation literal (`1e3`).
    static let bareIntegerRegex = try! NSRegularExpression(
        pattern: #"(?<![\d.eE])(\d+)(?![\d.eE])"#
    )

    /// Append `.0` to every bare integer literal in `input`. Returns
    /// the rewritten string. Pre-condition: `input` has already passed
    /// the `whitelistRegex` guard, so it contains only safe characters.
    static func coerceIntegersToDoubles(_ input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return bareIntegerRegex.stringByReplacingMatches(
            in: input,
            range: range,
            withTemplate: "$1.0"
        )
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
        let expr = parsed.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expr.isEmpty else {
            return ToolResult(output: "", error: "expression is empty")
        }
        guard expr.count <= Self.maxLength else {
            return ToolResult(output: "", error: "expression exceeds \(Self.maxLength) characters")
        }
        // Whitelist guard. Note: NOT a syntax check — that's
        // NSExpression's job. This is the security guard that keeps
        // FUNCTION: / SELF / variable references out of reach.
        let range = NSRange(expr.startIndex..., in: expr)
        guard Self.whitelistRegex.firstMatch(in: expr, range: range) != nil else {
            return ToolResult(output: "", error: "expression contains disallowed characters; only digits, + - * / ( ) . and scientific notation (e/E) are accepted")
        }
        // Coerce bare integer literals to doubles so `1 / 3` returns
        // 0.333… instead of integer-division 0. Models — and users
        // typing into a calculator — do not expect C-style integer
        // division here.
        let coerced = Self.coerceIntegersToDoubles(expr)
        // NSExpression's `format:` initialiser can throw at parse time
        // (unbalanced parens, stray operator) — wrap in a try/catch.
        // `expressionValue(with:context:)` evaluates the parsed AST;
        // arithmetic errors (division by zero) come back as an NSNumber
        // with a non-finite value, which we reject explicitly so the
        // model sees a clear error.
        let nsExpr: NSExpression
        do {
            nsExpr = NSExpression(format: coerced)
        }
        guard let value = nsExpr.expressionValue(with: nil, context: nil) as? NSNumber else {
            return ToolResult(output: "", error: "expression did not evaluate to a number")
        }
        let d = value.doubleValue
        guard d.isFinite else {
            return ToolResult(output: "", error: "result is not finite (division by zero or overflow)")
        }
        // Print integers without a trailing ".0" so the model can quote
        // results back to the user without unnecessary noise. Floats
        // use Swift's default `description`, which preserves enough
        // precision that round-tripping is lossless.
        if d == d.rounded(), abs(d) < 1e15 {
            return ToolResult(output: String(Int64(d)))
        }
        return ToolResult(output: String(d))
    }
}
