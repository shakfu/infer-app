import Foundation
import PluginAPI

/// Per-plugin row shown in Settings → Plugins. Built from
/// `PluginLoader.loadAll`'s `PluginLoadResult`, the original
/// `allPluginTypes` array (so plugins whose `register` threw still
/// appear in the table — without `types`, a failure-only result would
/// have no entry for that id and the user wouldn't know the plugin is
/// even compiled in), and the per-plugin config blobs (so the detail
/// view can show what's in `plugins.json` without re-reading the file).
struct PluginStatusEntry: Identifiable, Sendable, Equatable {
    /// One tool a loaded plugin contributed. Carrying the full
    /// `ToolSpec` (name + description) rather than just the name lets
    /// the detail view show *what* each tool does, not only that the
    /// plugin contributed N tools.
    struct ContributedTool: Sendable, Equatable {
        let name: ToolName
        let description: String
    }

    enum Status: Sendable, Equatable {
        case loaded(tools: [ContributedTool])
        case failed(message: String)
    }

    let id: String
    let status: Status
    /// JSON-encoded `config` blob from `plugins.json` for this plugin.
    /// Always present (defaults to `{}`); the detail view pretty-prints
    /// it for read-only display.
    let configJSON: Data

    var toolCount: Int {
        switch status {
        case .loaded(let tools): return tools.count
        case .failed: return 0
        }
    }

    /// Convenience for the row's compact display: comma-separated
    /// tool names. Empty for failed plugins.
    var toolNames: [ToolName] {
        switch status {
        case .loaded(let tools): return tools.map(\.name)
        case .failed: return []
        }
    }

    /// Build one entry per element of `types`, preserving order. Each
    /// id is matched against `result.contributions` (loaded path) or
    /// `result.failures` (error path); a plugin missing from both is
    /// reported as `loaded(tools: [])` — that case can only happen if
    /// a plugin's `register` returned successfully but contributed
    /// nothing, which is a legitimate "compiled in but inert" state.
    static func assemble(
        types: [any Plugin.Type],
        result: PluginLoadResult,
        configs: [String: PluginConfig]
    ) -> [PluginStatusEntry] {
        let failuresByID = Dictionary(
            uniqueKeysWithValues: result.failures.map { ($0.pluginID, $0.message) }
        )
        return types.map { type in
            let id = type.id
            let configJSON = configs[id]?.json ?? PluginConfig.empty.json
            if let message = failuresByID[id] {
                return PluginStatusEntry(
                    id: id,
                    status: .failed(message: message),
                    configJSON: configJSON
                )
            }
            let tools = (result.contributions[id]?.tools ?? [])
                .map { ContributedTool(name: $0.name, description: $0.spec.description) }
                .sorted { $0.name < $1.name }
            return PluginStatusEntry(
                id: id,
                status: .loaded(tools: tools),
                configJSON: configJSON
            )
        }
    }
}
