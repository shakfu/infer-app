import Foundation

/// Resolves a usable Quarto installation on the host without bundling
/// Quarto itself. The app stays small; the user controls upgrades.
///
/// Resolution order:
/// 1. Explicit override (e.g. from settings) — wins if it points at an
///    executable file.
/// 2. Login-shell PATH — `bash -lc 'command -v quarto'` picks up the
///    user's `~/.zprofile` / `~/.zshrc` additions (Homebrew on Apple
///    Silicon installs to `/opt/homebrew/bin`, which a GUI app launched
///    from Finder does not see by default).
/// 3. Common install locations — Homebrew (Intel + Apple Silicon),
///    `/Applications/quarto/bin/quarto`, `~/.local/bin/quarto`.
///
/// Returns `nil` when none of the strategies finds an executable. The
/// caller (settings UI, tool) is responsible for surfacing a clear
/// "install Quarto via `brew install quarto`" message.
public struct QuartoLocator: Sendable {
    public struct Install: Sendable, Equatable {
        public let url: URL
        /// Output of `quarto --version`, trimmed. Nil when the probe
        /// failed (executable found but didn't run cleanly — rare; a
        /// corrupted install). The locator still returns the install
        /// in that case so the UI can show "found, but version probe
        /// failed" rather than "not found".
        public let version: String?

        public init(url: URL, version: String?) {
            self.url = url
            self.version = version
        }
    }

    /// Closure that runs a process and returns (exitCode, stdout). The
    /// real implementation shells out via `Process`; tests inject a
    /// stub so the locator's logic is exercised without spawning real
    /// processes.
    public typealias Probe = @Sendable (_ executable: String, _ arguments: [String]) async -> (Int32, String)

    /// Default probe — runs the given executable with the given args
    /// and returns the captured stdout.
    public static let defaultProbe: Probe = { executable, arguments in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        p.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Optional explicit path (typically from `InferSettings.quartoPath`).
    public var override: String?
    /// Common install locations probed when PATH lookup misses. Order
    /// matters: first hit wins. Default covers Apple Silicon Homebrew,
    /// Intel Homebrew, the standalone `.pkg` install, and user-local.
    public var commonPaths: [String]
    /// Process probe — overridable for tests.
    public var probe: Probe

    public init(
        override: String? = nil,
        commonPaths: [String] = QuartoLocator.defaultCommonPaths(),
        probe: @escaping Probe = QuartoLocator.defaultProbe
    ) {
        self.override = override
        self.commonPaths = commonPaths
        self.probe = probe
    }

    public static func defaultCommonPaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/quarto",
            "/usr/local/bin/quarto",
            "/Applications/quarto/bin/quarto",
            "\(home)/.local/bin/quarto",
        ]
    }

    public func resolve() async -> Install? {
        if let override, let install = await probeIfExecutable(override) {
            return install
        }
        if let viaShell = await resolveViaLoginShell(),
           let install = await probeIfExecutable(viaShell) {
            return install
        }
        for path in commonPaths {
            if let install = await probeIfExecutable(path) {
                return install
            }
        }
        return nil
    }

    private func probeIfExecutable(_ path: String) async -> Install? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return nil
        }
        let (code, out) = await probe(url.path, ["--version"])
        let version = code == 0
            ? out.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return Install(url: url, version: version)
    }

    private func resolveViaLoginShell() async -> String? {
        // `bash -lc` re-runs the user's login dotfiles so PATH includes
        // Homebrew etc., even when the app was launched from Finder.
        let (code, out) = await probe("/bin/bash", ["-lc", "command -v quarto"])
        guard code == 0 else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
