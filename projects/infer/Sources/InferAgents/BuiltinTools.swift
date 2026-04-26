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
