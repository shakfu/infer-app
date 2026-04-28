import Foundation

/// A plugin is a compile-time SwiftPM target under
/// `projects/plugins/plugin_<name>/` that contributes tools (and, in
/// later PRs, agents and other surfaces) to the host app at startup.
///
/// Conformances are conventionally named `<UpperCamel(name)>Plugin`
/// (e.g. `WikiPlugin`) and live in the plugin's `Sources/plugin_<name>/`
/// directory. The build-time generator (`scripts/gen_plugins.py`) reads
/// `projects/plugins/plugins.json` and emits the
/// `allPluginTypes: [any Plugin.Type]` array consumed at startup.
///
/// `register` returns its contributions rather than pushing into a host
/// registry, so plugins remain pure declarations and `PluginAPI` stays
/// free of host-side state. The host loader collects contributions and
/// wires them into its own `ToolRegistry`. See `docs/dev/plugins.md`.
public protocol Plugin: Sendable {
    /// Stable identifier matching the `id` field in `plugins.json`. Use
    /// snake_case without the `plugin_` prefix (e.g. `"wiki"`, not
    /// `"plugin_wiki"`).
    static var id: String { get }

    /// Called once at app startup, before agents bootstrap. Decode any
    /// needed config and return the tools (and later: agents) the
    /// plugin contributes. A throw is caught by `PluginLoader`,
    /// recorded as a `PluginFailureRecord`, and surfaced via the
    /// host's warning sink — startup continues with the remaining
    /// plugins.
    ///
    /// `invoker` is bound to the host's tool registry — plugins that
    /// need to call other tools by name (their own, built-ins, or
    /// other plugins') capture it when constructing tools. Plugins
    /// that don't need cross-tool dispatch ignore the parameter. The
    /// closure dispatches against the registry as it stands at call
    /// time, not at register time, so plugin B can use it to reach
    /// plugin A even when A registers later in the load order.
    static func register(
        config: PluginConfig,
        invoker: @escaping ToolInvoker
    ) async throws -> PluginContributions
}

/// What a plugin returns from `register`. Additive: new contribution
/// kinds (agents, RAG sources, MCP server descriptors) get new fields
/// here without breaking existing plugins.
public struct PluginContributions: Sendable {
    public var tools: [any BuiltinTool]

    public init(tools: [any BuiltinTool] = []) {
        self.tools = tools
    }

    /// Convenience for plugins that contribute nothing this PR but
    /// want to compile against the substrate.
    public static let none = PluginContributions()
}
