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
    }

    private var entries: [AgentID: Entry] = [:]

    public init() {}

    /// Register `agent` from `source`. If an agent with the same id is
    /// already registered from a higher-precedence source, this is a
    /// no-op (the existing entry wins). Equal-precedence collisions
    /// replace (last writer wins) to keep the behaviour predictable when
    /// two user files declare the same id.
    @discardableResult
    public func register(_ agent: any Agent, source: AgentSource) -> Bool {
        if let existing = entries[agent.id], existing.source.precedence > source.precedence {
            return false
        }
        entries[agent.id] = Entry(agent: agent, source: source)
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
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: url)
                let agent = try decoder.decode(PromptAgent.self, from: data)
                register(agent, source: .user)
            } catch {
                errors.append(PersonaLoadError(url: url, message: String(describing: error)))
            }
        }
        return errors
    }

    public struct PersonaLoadError: Sendable, Equatable {
        public let url: URL
        public let message: String

        public init(url: URL, message: String) {
            self.url = url
            self.message = message
        }
    }
}
