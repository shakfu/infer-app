import SwiftUI
import AppKit
import InferAgents

/// Editor for the user's Quarto-executable override, with a live status
/// badge ("Quarto 1.9.37" / "not found" / "checking…") underneath the
/// path field.
///
/// Probe lifecycle:
/// - `.onAppear` → probe immediately (override if non-empty, else
///   auto-detect via `QuartoLocator`).
/// - User types in the path field → re-probe debounced 300 ms after
///   they stop, so the badge tracks what they're entering without
///   spawning a `bash -lc` per keystroke.
/// - "Detect" button → probe with no override and fill the field with
///   the located path. Useful for confirming what auto-detect would
///   pick; the badge then reflects that path.
/// - "Browse…" → `NSOpenPanel`, then probe.
/// - "Clear" → empty field, fall back to auto-detect.
///
/// All probe work runs on a detached Task; the `Process`-based locator
/// blocks for tens of milliseconds in the worst case (login-shell PATH
/// lookup), so doing it inline on the UI thread would visibly stutter.
struct QuartoSettingsRow: View {
    /// Bound through to `draft.quartoPath` (empty string → nil) by
    /// `SidebarView`. We keep the `String` (not `String?`) shape here
    /// so SwiftUI's `TextField` doesn't need a nil-aware binding.
    @Binding var path: String

    enum ProbeState: Equatable {
        case idle
        case checking
        case found(version: String?, resolvedPath: String)
        case notFound
    }

    @State private var probe: ProbeState = .idle
    @State private var debounceTask: Task<Void, Never>?
    @State private var cacheStats: CacheStats = .unknown

    enum CacheStats: Equatable {
        case unknown
        case empty
        case populated(fileCount: Int, totalBytes: Int64)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Quarto path").font(.caption)
                Spacer()
                if path.isEmpty {
                    Text("auto-detect").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 6) {
                TextField("auto-detect", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.caption.monospaced())
                    .onChange(of: path) { _, _ in scheduleProbe(debounce: true) }

                Button("Detect") {
                    Task { @MainActor in
                        probe = .checking
                        let install = await QuartoLocator(override: nil).resolve()
                        if let install {
                            path = install.url.path
                            probe = .found(version: install.version, resolvedPath: install.url.path)
                        } else {
                            probe = .notFound
                        }
                    }
                }
                .controlSize(.small)
                .help("Probe PATH and common install locations for `quarto`")

                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Select the quarto executable"
                    if panel.runModal() == .OK, let url = panel.url {
                        path = url.path
                    }
                }
                .controlSize(.small)

                Button("Clear") {
                    path = ""
                }
                .controlSize(.small)
                .disabled(path.isEmpty)
            }
            statusBadge
            Text("Empty = auto-detect via PATH. Install with `brew install quarto` if it isn't found.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            cacheControls
        }
        .onAppear {
            scheduleProbe(debounce: false)
            refreshCacheStats()
        }
    }

    /// Render-cache management. macOS doesn't garbage-collect
    /// `~/Library/Caches/` for us — this is the user's escape hatch.
    /// We don't auto-evict on render either; that's a deliberate
    /// choice to keep rendered files clickable from the chat
    /// disclosure indefinitely.
    @ViewBuilder
    private var cacheControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Render cache").font(.caption)
                Spacer()
                Text(cacheStatsLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Button("Show in Finder") {
                    revealCacheInFinder()
                }
                .controlSize(.small)
                .help("Reveals ~/Library/Caches/quarto-renders/ in Finder")

                Button("Clear…") {
                    confirmAndClearCache()
                }
                .controlSize(.small)
                .disabled(cacheStats == .empty || cacheStats == .unknown)
                .help("Delete every rendered file under the cache directory")
            }
            Text("macOS does not auto-clean app caches. Rendered files stay until you remove them.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cacheStatsLabel: String {
        switch cacheStats {
        case .unknown: return "—"
        case .empty: return "empty"
        case .populated(let count, let bytes):
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "\(count) file\(count == 1 ? "" : "s") · \(formatted)"
        }
    }

    private func revealCacheInFinder() {
        guard let url = try? QuartoRunner.cacheDirectory() else { return }
        // Create the dir lazily so Finder doesn't show "folder doesn't
        // exist" before the user's first render.
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func confirmAndClearCache() {
        let alert = NSAlert()
        alert.messageText = "Clear Quarto render cache?"
        alert.informativeText = "Every rendered file under ~/Library/Caches/quarto-renders/ will be deleted. Links from past chat messages to those files will stop working."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            await Self.clearCache()
            refreshCacheStats()
        }
    }

    /// Walks the cache directory and removes every entry. Errors per
    /// file are swallowed (best-effort) — the next refresh will reflect
    /// what actually got removed. Off the main actor because
    /// `removeItem` is synchronous and the directory could (in theory)
    /// be large.
    private static func clearCache() async {
        await Task.detached {
            let fm = FileManager.default
            guard let dir = try? QuartoRunner.cacheDirectory(),
                  let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                return
            }
            for url in contents {
                try? fm.removeItem(at: url)
            }
        }.value
    }

    /// Recompute file count + total bytes. Off the main actor because
    /// directory enumeration is synchronous and could stat dozens of
    /// files. Cheap in practice (each render is one file).
    private func refreshCacheStats() {
        Task { @MainActor in
            let stats = await Self.computeCacheStats()
            self.cacheStats = stats
        }
    }

    private static func computeCacheStats() async -> CacheStats {
        await Task.detached {
            let fm = FileManager.default
            guard let dir = try? QuartoRunner.cacheDirectory() else { return .unknown }
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) else {
                // Directory doesn't exist yet — treat as empty so the
                // Clear button stays disabled.
                return .empty
            }
            if contents.isEmpty { return .empty }
            var bytes: Int64 = 0
            var count = 0
            for url in contents {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true {
                    bytes += Int64(values?.fileSize ?? 0)
                    count += 1
                }
            }
            return count == 0 ? .empty : .populated(fileCount: count, totalBytes: bytes)
        }.value
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch probe {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("checking…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .found(let version, let resolvedPath):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text(version.map { "Quarto \($0)" } ?? "Quarto found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if path.isEmpty {
                    // User left the field blank — show which install
                    // auto-detect picked so they know what's running.
                    Text("(\(resolvedPath))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .notFound:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("not found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Re-probe the locator with the current `path` (or no override
    /// when empty). When `debounce` is true, wait 300 ms and cancel any
    /// in-flight probe — keystrokes during typing don't each spawn a
    /// process. When false (initial appear), probe immediately.
    private func scheduleProbe(debounce: Bool) {
        debounceTask?.cancel()
        let override = path.isEmpty ? nil : path
        let task = Task { @MainActor in
            if debounce {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            probe = .checking
            let install = await QuartoLocator(override: override).resolve()
            if Task.isCancelled { return }
            if let install {
                probe = .found(version: install.version, resolvedPath: install.url.path)
            } else {
                probe = .notFound
            }
        }
        debounceTask = task
    }
}
