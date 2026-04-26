import Foundation

/// Outcome of asking the host whether a given MCP server should be
/// allowed to register tools. `allowOnce` runs the server for this
/// session but doesn't persist; `allowAlways` writes the approval to
/// the store so future bootstraps skip the prompt.
public enum MCPApprovalDecision: Sendable, Equatable {
    case allowAlways
    case allowOnce
    case deny
}

/// Closure the host wires up to consult the user (or a remembered
/// answer) when an unknown MCP server appears at bootstrap. The
/// default provider lives below — it consults `MCPApprovalStore` and
/// returns `.deny` for anything not previously approved, which is the
/// secure default for a feature that can spawn arbitrary subprocesses.
///
/// A real UI host wraps this with a SwiftUI alert / sheet that lets
/// the user pick `allowOnce` / `allowAlways` / `deny` and persists
/// the answer through the store. Tests use a scripted closure.
public typealias MCPApprovalProvider = @Sendable (MCPServerConfig) async -> MCPApprovalDecision

/// Persistence layer for "user approved this MCP server" facts.
/// Backed by `UserDefaults` so the answer survives app restarts
/// without dragging in the file system.
///
/// The store is intentionally minimal — a `Set<String>` of approved
/// server IDs under one defaults key. Approvals are by id; if two
/// configs reuse the same id the second silently inherits the first
/// one's approval (the configs collide on id at bootstrap regardless,
/// so the surface stays sane).
///
/// Threading: `UserDefaults` is documented thread-safe for the basic
/// get/set used here. The store is a value-type wrapper around it so
/// callers don't have to thread an actor reference through.
public struct MCPApprovalStore: @unchecked Sendable {
    public static let defaultsKey = "mcp.approvedServers"

    // UserDefaults isn't `Sendable` in the strict-concurrency model,
    // but the operations we use (array get / set under one key) are
    // documented thread-safe. The `@unchecked` is the price of
    // crossing the boundary cleanly without a wrapping actor.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isApproved(serverID: String) -> Bool {
        approvedSet().contains(serverID)
    }

    public func approve(serverID: String) {
        var set = approvedSet()
        set.insert(serverID)
        write(set)
    }

    public func revoke(serverID: String) {
        var set = approvedSet()
        set.remove(serverID)
        write(set)
    }

    public func approvedServers() -> Set<String> {
        approvedSet()
    }

    private func approvedSet() -> Set<String> {
        Set(defaults.array(forKey: Self.defaultsKey) as? [String] ?? [])
    }

    private func write(_ set: Set<String>) {
        // Sort for deterministic on-disk shape (helps a user who
        // peeks at the plist).
        defaults.set(Array(set).sorted(), forKey: Self.defaultsKey)
    }
}

/// Default approval provider: consult the store, return `.allowOnce`
/// for already-approved servers (no need to re-persist), `.deny` for
/// anything else. A host UI replaces this with a closure that prompts
/// the user on `.deny` and persists the answer through the store
/// before returning.
public func defaultMCPApprovalProvider(
    store: MCPApprovalStore = MCPApprovalStore()
) -> MCPApprovalProvider {
    return { config in
        if config.autoApprove { return .allowOnce }
        return store.isApproved(serverID: config.id) ? .allowOnce : .deny
    }
}
