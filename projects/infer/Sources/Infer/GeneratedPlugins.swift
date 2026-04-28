// GENERATED — do not hand-edit. Run `make plugins-gen` to regenerate
// from `projects/plugins/plugins.json`.
import Foundation
import PluginAPI
import plugin_wiki
import plugin_python_tools

/// Order matches `plugins.json`. The loader iterates this array and
/// looks up each plugin's `config` in `pluginConfigs` by `Plugin.id`.
public let allPluginTypes: [any Plugin.Type] = [
    WikiPlugin.self,
    PythonToolsPlugin.self,
]

/// JSON-encoded `config` blob per plugin id, mirroring the `config`
/// objects in `plugins.json`. Plugins decode via `PluginConfig.decode`.
public let pluginConfigs: [String: PluginConfig] = [
    "wiki": PluginConfig(json: Data("{}".utf8)),
    "python_tools": PluginConfig(json: Data("{}".utf8)),
]
