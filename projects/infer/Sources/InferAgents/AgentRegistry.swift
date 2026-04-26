import Foundation

/// Actor-isolated registry of all agents known to the app.
///
/// Sources (user-authored JSON, plugin-shipped, first-party compiled) are
/// registered through `register(_:source:)`. On `AgentID` collision the
/// higher-precedence source wins: user > plugin > firstParty. See
/// `docs/dev/agents.md` for why this is cosmetic under "all in-tree"
/// plugins (the source tag is displayed for transparency; there is no
/// runtime trust distinction).
public actor AgentRegistry {
    public struct Entry: Sendable {
        public let agent: any Agent
        public let source: AgentSource
        /// On-disk JSON URL for personas/agents loaded from a file.
        /// Nil for compiled conformances (`DefaultAgent`) and for
        /// agents registered without an underlying file. Used by
        /// composition-reference validation to attribute diagnostics
        /// back to the offending file.
        public let sourceURL: URL?

        public init(agent: any Agent, source: AgentSource, sourceURL: URL? = nil) {
            self.agent = agent
            self.source = source
            self.sourceURL = sourceURL
        }
    }

    private var entries: [AgentID: Entry] = [:]

    public init() {}

    /// Register `agent` from `source`. If an agent with the same id is
    /// already registered from a higher-precedence source, this is a
    /// no-op (the existing entry wins). Equal-precedence collisions
    /// replace (last writer wins) to keep the behaviour predictable when
    /// two user files declare the same id.
    @discardableResult
    public func register(
        _ agent: any Agent,
        source: AgentSource,
        sourceURL: URL? = nil
    ) -> Bool {
        if let existing = entries[agent.id], existing.source.precedence > source.precedence {
            return false
        }
        entries[agent.id] = Entry(agent: agent, source: source, sourceURL: sourceURL)
        return true
    }

    public func agent(id: AgentID) -> (any Agent)? {
        entries[id]?.agent
    }

    public func entry(id: AgentID) -> Entry? {
        entries[id]
    }

    public func allEntries() -> [Entry] {
        Array(entries.values)
    }

    /// Load every `*.json` file in `directory` as a `PromptAgent`, and
    /// register each successfully-parsed file under `.user`.
    ///
    /// Parse failures do not abort the load: each file's error is
    /// appended to the returned `errors` list so the caller (typically
    /// the Agents tab) can surface per-file reasons without losing
    /// partial progress. Missing directory is not an error — it just
    /// means no user personas are installed.
    @discardableResult
    public func loadUserPersonas(from directory: URL) -> [PersonaLoadError] {
        var errors: [PersonaLoadError] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return errors
        }
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            errors.append(PersonaLoadError(url: directory, message: "contentsOfDirectory: \(error.localizedDescription)"))
            return errors
        }
        for url in urls where url.pathExtension.lowercased() == "json" {
            do {
                let agent = try Self.decodePersona(at: url)
                register(agent, source: .user, sourceURL: url)
            } catch {
                errors.append(PersonaLoadError(url: url, message: String(describing: error)))
            }
        }
        return errors
    }

    /// Decode a `PromptAgent` JSON file with the source URL threaded into
    /// `decoder.userInfo` so `PromptAgent.init(from:)` can resolve a
    /// `contextPath` sidecar relative to the file's directory. Shared by
    /// `loadUserPersonas` here and `AgentController.loadFirstPartyPersonas`.
    public static func decodePersona(at url: URL) throws -> PromptAgent {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.userInfo[.personaSourceURL] = url
        return try decoder.decode(PromptAgent.self, from: data)
    }

    /// After all personas/agents are loaded, walk every agent's
    /// composition references (`chain`, `fallback`,
    /// `orchestrator.{router, candidates}`) and produce diagnostics for
    /// any reference that doesn't resolve, plus any cycle reachable
    /// through chain/fallback edges. Cycles + missing references are
    /// surfaced as `.warning` severity — the agent loads, the
    /// composition runtime later refuses to dispatch a broken edge,
    /// and the user sees the diagnostic in the Agents tab.
    ///
    /// Cost: O(N + E) over agents and edges. Run once at the tail of
    /// `bootstrap`.
    public func validateCompositionReferences() -> [PersonaLoadError] {
        var errors: [PersonaLoadError] = []
        let entries = self.entries
        let known = Set(entries.keys)

        for entry in entries.values {
            guard let agent = entry.agent as? PromptAgent else { continue }
            let url = entry.sourceURL ?? URL(fileURLWithPath: "/dev/null")

            for ref in agent.chain ?? [] where !known.contains(ref) {
                errors.append(PersonaLoadError(
                    url: url,
                    message: "agent \"\(agent.id)\" chain references unknown agent \"\(ref)\"",
                    severity: .warning
                ))
            }
            for ref in agent.fallback ?? [] where !known.contains(ref) {
                errors.append(PersonaLoadError(
                    url: url,
                    message: "agent \"\(agent.id)\" fallback references unknown agent \"\(ref)\"",
                    severity: .warning
                ))
            }
            if let orch = agent.orchestrator {
                if !known.contains(orch.router) {
                    errors.append(PersonaLoadError(
                        url: url,
                        message: "agent \"\(agent.id)\" orchestrator.router \"\(orch.router)\" not found",
                        severity: .warning
                    ))
                }
                for cand in orch.candidates where !known.contains(cand) {
                    errors.append(PersonaLoadError(
                        url: url,
                        message: "agent \"\(agent.id)\" orchestrator candidate \"\(cand)\" not found",
                        severity: .warning
                    ))
                }
                if orch.candidates.contains(orch.router) {
                    errors.append(PersonaLoadError(
                        url: url,
                        message: "agent \"\(agent.id)\" orchestrator.router cannot also be a candidate",
                        severity: .warning
                    ))
                }
            }
        }

        // Detect chain cycles. An agent's chain says "after I'm done,
        // route to A then B"; mutual chains (A→B, B→A) loop forever.
        // Build an adjacency list from chain + fallback edges and run
        // a depth-limited DFS for self-reachability.
        var adjacency: [AgentID: [AgentID]] = [:]
        for entry in entries.values {
            guard let agent = entry.agent as? PromptAgent else { continue }
            var edges: [AgentID] = []
            edges.append(contentsOf: agent.chain ?? [])
            edges.append(contentsOf: agent.fallback ?? [])
            adjacency[agent.id] = edges
        }
        for source in adjacency.keys {
            if Self.reachesItself(source: source, adjacency: adjacency) {
                let url = entries[source]?.sourceURL
                    ?? URL(fileURLWithPath: "/dev/null")
                errors.append(PersonaLoadError(
                    url: url,
                    message: "agent \"\(source)\" composition cycle detected",
                    severity: .warning
                ))
            }
        }

        return errors
    }

    /// DFS from `source`, traversing `adjacency` edges, returning true
    /// if `source` is itself reachable along any path.
    private static func reachesItself(
        source: AgentID,
        adjacency: [AgentID: [AgentID]]
    ) -> Bool {
        var visited = Set<AgentID>()
        var stack: [AgentID] = adjacency[source] ?? []
        while let next = stack.popLast() {
            if next == source { return true }
            if !visited.insert(next).inserted { continue }
            stack.append(contentsOf: adjacency[next] ?? [])
        }
        return false
    }

    public struct PersonaLoadError: Sendable, Equatable {
        public let url: URL
        public let message: String
        public let severity: Severity

        /// `agent-ux-plan.md` §0.3: diagnostics are surfaced with a
        /// severity so the UI can distinguish "this file couldn't load
        /// at all" (skipped) from "this file loaded but something looks
        /// off" (warning). Defaults to `.skipped` so existing call
        /// sites — which only ever wrote hard-fail records — keep their
        /// historical semantics without explicit annotation.
        public enum Severity: Sendable, Equatable {
            case skipped
            case warning
        }

        public init(url: URL, message: String, severity: Severity = .skipped) {
            self.url = url
            self.message = message
            self.severity = severity
        }
    }
}
