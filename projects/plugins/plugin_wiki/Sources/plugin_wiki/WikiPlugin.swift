import Foundation
import PluginAPI

/// Placeholder shipped in PR-A so the plugin substrate has a concrete
/// consumer. PR-B replaces this with the real wiki implementation
/// (vault migration v5_wiki, `WikiStore`, `wiki.read` / `wiki.write` /
/// `wiki.search` / `wiki.list` / `wiki.delete`, plus the Note-taker
/// agent) per `docs/dev/wiki.md`.
public enum WikiPlugin: Plugin {
    public static let id = "wiki"

    public static func register(config _: PluginConfig) async throws -> PluginContributions {
        PluginContributions(tools: [WikiPingTool()])
    }
}

/// Stand-in tool that proves the registration path end-to-end. Returns
/// a static "ok" response so any agent that opts into `wiki.ping` in
/// its `requirements.toolsAllow` can call it without touching disk
/// or network. Removed in PR-B when the real `wiki.*` family lands.
struct WikiPingTool: BuiltinTool {
    let name: ToolName = "wiki.ping"

    var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Health-check tool from plugin_wiki. Returns the literal string \"ok\". Useful only for confirming the plugin substrate loaded; will be removed when the real wiki tools land. Call with an empty parameters object: {}."
        )
    }

    func invoke(arguments _: String) async throws -> ToolResult {
        ToolResult(output: "ok")
    }
}
