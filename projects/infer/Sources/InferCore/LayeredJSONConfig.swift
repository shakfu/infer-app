import Foundation

/// Generic layered loader for a `Decodable` config payload backed by
/// JSON, with three layers consulted in order:
///
///   1. **User override** — `~/Library/Application Support/Infer/<filename>`.
///      Whatever the user has authored, including partial overrides.
///   2. **Bundled defaults** — `Bundle.module`'s `<resourceName>.json`.
///      Edited and shipped with each release.
///   3. **Hardcoded fallback** — supplied at construction time via
///      `defaultValue`. Used only when neither layer above parses; safety
///      net for a corrupt or missing JSON.
///
/// First read on a given instance loads through all three layers, caches
/// the result, and returns it. Subsequent reads are O(1) until the
/// process exits — relaunch to pick up changes to either JSON. Hot-reload
/// would require `FSEventStream` plumbing not worth the complexity for
/// configs that change weekly at most.
///
/// Used for: `cloud-models.json`, `cloud-providers.json`,
/// `local-models.json`. Each callsite supplies a `Decodable` payload
/// type, the resource basename (`"CloudModels"` etc.), the user-override
/// filename (`"cloud-models.json"` etc.), and a hardcoded fallback value
/// of the same type.
///
/// Concurrency: `@unchecked Sendable` because the cache is mutated
/// behind an `NSLock`. Callers should cache the `LayeredJSONConfig`
/// itself (typically as a `static let` next to the consumer) so the
/// memo lasts the process lifetime.
public final class LayeredJSONConfig<Payload: Decodable & Sendable>: @unchecked Sendable {
    /// Bundle resource basename — `<resourceName>.json` in the bundle's
    /// `Resources/`. Path traversal is intentionally restricted: this
    /// is a constant baked into the consumer, not user input.
    private let resourceName: String
    /// User-override filename relative to `~/Library/Application Support/Infer/`.
    /// Conventionally a kebab-case `<thing>.json` paralleling the bundle's
    /// `<Thing>.json` (PascalCase) — paralleled because the bundle is a
    /// developer-shipped artifact while the override is a user-edited
    /// file, and the casing convention helps distinguish at a glance.
    private let userFilename: String
    /// The bundle that owns the resource. Almost always `Bundle.module`
    /// for an `InferCore` consumer; explicit so a downstream target
    /// could supply its own bundle if it wanted to layer its own JSON.
    private let bundle: Bundle
    /// Hardcoded last-resort value. Returned when both JSON layers
    /// fail to parse — keeps the system functioning rather than
    /// crashing on a corrupt user file.
    private let defaultValue: Payload

    private let cacheLock = NSLock()
    private var cached: Payload?

    public init(
        resourceName: String,
        userFilename: String,
        bundle: Bundle,
        defaultValue: Payload
    ) {
        self.resourceName = resourceName
        self.userFilename = userFilename
        self.bundle = bundle
        self.defaultValue = defaultValue
    }

    /// Resolve the layered value. First call loads and caches; later
    /// calls are O(1). Thread-safe via `cacheLock`.
    public func resolve() -> Payload {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached { return cached }
        let value = resolveOnce()
        cached = value
        return value
    }

    private func resolveOnce() -> Payload {
        // 1. User override.
        if let userURL = userOverrideURL,
           let data = try? Data(contentsOf: userURL),
           let parsed = try? JSONDecoder().decode(Payload.self, from: data) {
            return parsed
        }
        // 2. Bundled.
        if let bundledURL = bundle.url(forResource: resourceName, withExtension: "json"),
           let data = try? Data(contentsOf: bundledURL),
           let parsed = try? JSONDecoder().decode(Payload.self, from: data) {
            return parsed
        }
        // 3. Hardcoded.
        return defaultValue
    }

    private var userOverrideURL: URL? {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return appSupport
            .appendingPathComponent("Infer", isDirectory: true)
            .appendingPathComponent(userFilename)
    }
}
