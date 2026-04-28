// GENERATED — do not hand-edit. Run `make plugins-gen` to regenerate
// from `projects/plugins/plugins.json`.
import Foundation
import PluginAPI
import plugin_hacker_news
import plugin_python_tools

/// Order matches `plugins.json`. The loader iterates this array and
/// looks up each plugin's `config` in `pluginConfigs` by `Plugin.id`.
public let allPluginTypes: [any Plugin.Type] = [
    HackerNewsPlugin.self,
    PythonToolsPlugin.self,
]

/// JSON-encoded `config` blob per plugin id, mirroring the `config`
/// objects in `plugins.json`. Plugins decode via `PluginConfig.decode`.
public let pluginConfigs: [String: PluginConfig] = [
    "hacker_news": PluginConfig(json: Data("{}".utf8)),
    "python_tools": PluginConfig(json: Data("{}".utf8)),
]
