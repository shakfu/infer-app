import Foundation

/// Opaque per-plugin configuration. The build-time generator embeds
/// the `config` object from `projects/plugins/plugins.json` for each
/// enabled plugin; the loader hands the matching `PluginConfig` to
/// `Plugin.register(config:)`.
///
/// Plugins decode what they expect and throw on missing/invalid fields.
/// The decode failure surfaces through the same per-plugin error path
/// as any other `register` throw — see `docs/dev/plugins.md` "Failure
/// during register". No build-time JSON Schema; we revisit that when
/// the plugin count justifies it.
public struct PluginConfig: Sendable {
    /// JSON-encoded form of the original `config` object. Stored as
    /// `Data` rather than `Any` so the type is `Sendable` and so
    /// `decode(_:)` is one round-trip through `JSONDecoder`.
    public let json: Data

    public init(json: Data) {
        self.json = json
    }

    /// Empty `{}` config — the loader's fallback when a plugin's id
    /// has no entry in `pluginConfigs`.
    public static let empty = PluginConfig(json: Data("{}".utf8))

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: json)
    }
}
