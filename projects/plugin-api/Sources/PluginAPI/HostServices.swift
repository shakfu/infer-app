import Foundation

/// Filesystem-root categories a plugin can ask the host to resolve.
///
/// New cases are additive: a plugin that asks for a category the host
/// does not recognise will receive an empty list (the host implementation
/// is the single source of truth, not the enum). Plugins MUST NOT widen
/// the returned set; the resolver is the only sanctioned way to obtain
/// allowed sandbox roots, and silently expanding past what was returned
/// is a sandbox-policy break.
public enum SandboxRootCategory: String, Sendable, CaseIterable {
    /// User's primary documents area (`~/Documents` on macOS). Default
    /// drop point for files the user wants the agent to operate on.
    case userDocuments

    /// Per-user agents-resources root
    /// (`~/Library/Application Support/Infer/`). Holds persona-bundled
    /// assets, agent JSON, MCP server configs. Used by tools that
    /// also need to read host-side metadata.
    case agentsRoot
}

/// Host-provided service that resolves canonical filesystem roots for
/// sandboxed tools. Plugins call this at `register` time to obtain the
/// set of roots the host has authorized for a given category, then pass
/// the result into each tool's `allowedRoots` constructor parameter.
///
/// Centralizing the policy here means a host-side change (e.g. tighten
/// `userDocuments` to `~/Documents/Infer/`) takes effect across every
/// plugin without per-plugin edits. Plugins that hardcoded their own
/// roots would silently drift; using this resolver makes that class of
/// drift impossible.
public protocol SandboxResolver: Sendable {
    /// Absolute file URLs the host has authorized for `category`.
    /// Empty when the host elects not to grant the category (e.g. in a
    /// stripped-down build flavor or under a future "lockdown" toggle);
    /// callers must treat empty as "no access" and surface a clear
    /// diagnostic rather than silently widening to a default.
    func roots(for category: SandboxRootCategory) -> [URL]
}

/// Bag of host-provided services threaded into `Plugin.register`.
/// Additive: new services land as new properties without breaking
/// existing plugin signatures, since plugins ignore properties they
/// don't reference. The host owns one canonical implementation and
/// passes the same instance to every plugin.
public protocol HostServices: Sendable {
    /// Filesystem-root resolver. See `SandboxResolver` for the contract.
    var sandbox: any SandboxResolver { get }
}
