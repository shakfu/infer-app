import Foundation
import PluginAPI

/// Host-side `HostServices` implementation. One instance is constructed
/// at plugin-load time in `Agents.swift` and handed to every plugin's
/// `register(config:invoker:host:)`.
///
/// The sandbox-resolver in particular is the *single source of truth*
/// for which filesystem roots a plugin-contributed sandboxed tool may
/// touch. Built-in tools in `Agents.swift` are wired with the same
/// roots out of the same helpers, so a host-side policy change (e.g.
/// adding `~/Downloads` to `userDocuments`) propagates to plugin and
/// built-in tools in lockstep without per-tool edits.
struct PluginHostServices: HostServices {
    let sandbox: any SandboxResolver
}

/// Concrete `SandboxResolver`. The roots come from the same statics
/// (`ChatViewModel.userAgentsRootDirectory`, `~/Documents`) that
/// built-in tools in `Agents.swift` already use, so plugin policy is
/// pinned to host policy by construction.
struct DefaultSandboxResolver: SandboxResolver {
    func roots(for category: SandboxRootCategory) -> [URL] {
        switch category {
        case .userDocuments:
            // `NSHomeDirectory()` returns the user's actual home in the
            // app process and the test runner's host-bundle parent in
            // tests; both are correct for the "sandboxed file ops live
            // under the user's Documents" semantics.
            return [
                URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Documents", isDirectory: true)
            ]
        case .agentsRoot:
            return [ChatViewModel.userAgentsRootDirectory()]
        }
    }
}
