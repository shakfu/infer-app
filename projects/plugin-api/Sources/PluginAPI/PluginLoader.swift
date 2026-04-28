import Foundation

/// One-line description of a plugin failure for surfacing through the
/// host's warning sink. Returned by `PluginLoader.loadAll` so the
/// executable can route each failure into its existing log center
/// without `PluginAPI` needing to know about it.
public struct PluginFailureRecord: Sendable {
    public let pluginID: String
    public let message: String

    public init(pluginID: String, message: String) {
        self.pluginID = pluginID
        self.message = message
    }
}

/// Result of running every plugin's `register`. `contributions` is
/// keyed by `Plugin.id` for plugins whose `register` returned
/// successfully; `failures` carries one record per plugin whose
/// `register` threw (logged + surfaced by the caller).
public struct PluginLoadResult: Sendable {
    public var contributions: [String: PluginContributions]
    public var failures: [PluginFailureRecord]

    public init(
        contributions: [String: PluginContributions] = [:],
        failures: [PluginFailureRecord] = []
    ) {
        self.contributions = contributions
        self.failures = failures
    }
}

public enum PluginLoader {
    /// Run every plugin's `register`, looking up each plugin's config
    /// in `configs` by `Plugin.id` and threading `invoker` so plugins
    /// can dispatch other tools by name at call time. Catches
    /// per-plugin errors and returns them on `result.failures`;
    /// remaining plugins still register. Order in `types` is preserved
    /// (the generator emits the order from `plugins.json`).
    public static func loadAll(
        types: [any Plugin.Type],
        configs: [String: PluginConfig],
        invoker: @escaping ToolInvoker
    ) async -> PluginLoadResult {
        var result = PluginLoadResult()
        for pluginType in types {
            let id = pluginType.id
            let config = configs[id] ?? .empty
            do {
                let contrib = try await pluginType.register(config: config, invoker: invoker)
                result.contributions[id] = contrib
            } catch {
                result.failures.append(PluginFailureRecord(
                    pluginID: id,
                    message: String(describing: error)
                ))
            }
        }
        return result
    }
}
