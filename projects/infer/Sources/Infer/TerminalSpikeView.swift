import SwiftUI
import AppKit
import SwiftTerm

// SPIKE — embedded terminal (SwiftTerm), rendered as a main-content tab.
//
// This first cut uses `LocalProcessTerminalView`, which bundles the PTY,
// child process, and rendering together and implements the large
// `TerminalViewDelegate` internally — we only implement the 4-method
// `LocalProcessTerminalViewDelegate`.
//
// NEXT STEP (the actual agent feature): for agent transparency we don't
// want `LocalProcessTerminalView` — it feeds child output straight into
// the emulator with no tee. The real path drives commands through
// SwiftTerm's lower-level `LocalProcess` (whose `dataReceived(slice:)`
// delegate hands us the raw bytes), then fans those bytes out two ways:
// `feed(byteArray:)` for the human-visible render AND the agent's stdout
// consumer. One source, clean tee, no grid-scraping.

/// Retains the terminal's AppKit view + delegate **outside** the SwiftUI
/// view tree so switching tabs doesn't tear down and respawn the shell.
/// The content area is a `switch` that drops the inactive branch, so a
/// view created inside it would be deallocated on every tab switch —
/// killing the child process and losing scrollback. `ChatViewModel` owns
/// one of these lazily; the representable just re-parents `view`.
@MainActor
final class TerminalSession {
    let view: LocalProcessTerminalView
    private let coordinator: Coordinator

    init() {
        let view = LocalProcessTerminalView(frame: .zero)
        let coordinator = Coordinator()
        view.processDelegate = coordinator

        // Launch the user's login shell. `environment: nil` lets SwiftTerm
        // supply its own minimal default (TERM, etc.); a real integration
        // would forward a curated environment.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        view.startProcess(
            executable: shell,
            args: ["-l"],
            environment: nil,
            execName: nil,
            currentDirectory: NSHomeDirectory()
        )
        coordinator.process = view
        self.view = view
        self.coordinator = coordinator
    }

    /// Kill the child process. Called when the terminal tab is closed and
    /// from app teardown; the session is dropped afterwards so a reopen
    /// starts a fresh shell.
    func terminate() {
        view.terminate()
    }

    // SwiftTerm's `LocalProcessTerminalViewDelegate` is a `nonisolated`
    // protocol (it's compiled in Swift 5 mode), but the view drives these
    // callbacks on the main thread. Swift 6.1 *isolated conformances*
    // (`@MainActor` before the protocol) let a main-actor type satisfy a
    // nonisolated protocol without `nonisolated` hops — sound here because
    // the conformance is only ever used from the main actor.
    @MainActor
    final class Coordinator: NSObject, @MainActor LocalProcessTerminalViewDelegate {
        weak var process: LocalProcessTerminalView?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}

/// SwiftUI bridge that re-parents the session's retained AppKit view.
/// Stateless — all lifecycle lives in `TerminalSession`.
struct TerminalTabView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView { session.view }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
