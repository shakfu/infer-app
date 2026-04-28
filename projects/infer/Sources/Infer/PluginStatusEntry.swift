import Foundation
import PluginAPI

/// Per-plugin row shown in Settings → Plugins. Built from
/// `PluginLoader.loadAll`'s `PluginLoadResult` plus the original
/// `allPluginTypes` array (so plugins whose `register` threw still
/// appear in the table — without `types`, a failure-only result
/// would have no entry for that id and the user wouldn't know the
/// plugin is even compiled in).
struct PluginStatusEntry: Identifiable, Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case loaded(toolNames: [ToolName])
        case failed(message: String)
    }

    let id: String
    let status: Status

    var toolCount: Int {
        switch status {
        case .loaded(let names): return names.count
        case .failed: return 0
        }
    }

    /// Build one entry per element of `types`, preserving order. Each
    /// id is matched against `result.contributions` (loaded path) or
    /// `result.failures` (error path); a plugin missing from both is
    /// reported as `loaded(toolNames: [])` — that case can only
    /// happen if a plugin's `register` returned successfully but
    /// contributed nothing, which is a legitimate "compiled in but
    /// inert" state.
    static func assemble(
        types: [any Plugin.Type],
        result: PluginLoadResult
    ) -> [PluginStatusEntry] {
        let failuresByID = Dictionary(
            uniqueKeysWithValues: result.failures.map { ($0.pluginID, $0.message) }
        )
        return types.map { type in
            let id = type.id
            if let message = failuresByID[id] {
                return PluginStatusEntry(id: id, status: .failed(message: message))
            }
            let toolNames = (result.contributions[id]?.tools.map(\.name) ?? [])
                .sorted()
            return PluginStatusEntry(id: id, status: .loaded(toolNames: toolNames))
        }
    }
}
