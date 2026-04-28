import SwiftUI
import AppKit

/// One row per compiled-in plugin (entries reflect what's in
/// `projects/plugins/plugins.json`). Loaded plugins show the tools
/// they contributed; failed plugins show the error message inline so
/// the user can act without digging through the Console scrollback.
///
/// Each row is expandable into a detail view that shows the full
/// `config` blob from `plugins.json`, every tool's description, and
/// the failure message in full (when applicable). Editable
/// configuration / runtime enable-toggle / autoApprove-list editing
/// are deferred — `plugins.json` is the source of truth for both
/// build and runtime state today, and editing it inside the app
/// would need a rebuild prompt that isn't worth wiring until the
/// runtime-toggle PR (PR-C) lands.
struct PluginsSettingsView: View {
    let entries: [PluginStatusEntry]
    @State private var expandedID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            row(for: entry)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plugins")
                .font(.title3.weight(.semibold))
            Text("Compile-time extensions from `projects/plugins/`. The set of plugins in this build is fixed by `projects/plugins/plugins.json`; changes require `make plugins-gen` and a rebuild.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No plugins compiled in.")
                .foregroundStyle(.secondary)
            Text("Add an entry to `projects/plugins/plugins.json` and run `make plugins-gen && make build`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                revealPluginsJSONInFinder()
            } label: {
                Label("Reveal plugins.json in Finder", systemImage: "folder")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func row(for entry: PluginStatusEntry) -> some View {
        let isExpanded = (expandedID == entry.id)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expandedID = isExpanded ? nil : entry.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    statusPill(for: entry.status)
                    Text(entry.id)
                        .font(.body.monospaced().weight(.medium))
                    Spacer()
                    if case .loaded = entry.status {
                        Text("\(entry.toolCount) tool\(entry.toolCount == 1 ? "" : "s")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Compact inline summary (always visible, even when not expanded)
            switch entry.status {
            case .loaded(let tools) where !tools.isEmpty:
                Text(tools.map(\.name).joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 20)
            case .loaded:
                Text("Plugin loaded but contributed no tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(isExpanded ? nil : 2)
                    .padding(.leading, 20)
            }

            if isExpanded {
                detail(for: entry)
                    .padding(.leading, 20)
                    .padding(.top, 4)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private func detail(for entry: PluginStatusEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            // Per-tool descriptions (loaded path only). Tool descriptions
            // are usually multi-sentence — we render each as its own
            // block so the user can read what the tool actually does.
            if case .loaded(let tools) = entry.status, !tools.isEmpty {
                Text("Tools").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(tools, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                            .font(.caption.monospaced().weight(.medium))
                        if !tool.description.isEmpty {
                            Text(tool.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            // Pretty-printed config blob.
            Text("Config").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(prettyConfig(entry.configJSON))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.15))
                )
                .textSelection(.enabled)

            Text("Edit `projects/plugins/plugins.json` and rerun `make plugins-gen && make build` to change. In-app editing lands when the runtime enable/disable toggle does.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Re-encode the stored JSON with `.prettyPrinted` so the user
    /// sees `{ "k": "v" }` over multiple lines instead of the compact
    /// form the generator emits. Falls back to the raw bytes (UTF-8
    /// decoded) on parse failure — defensive only; the generator
    /// always emits valid JSON.
    private func prettyConfig(_ data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let str = String(data: pretty, encoding: .utf8)
        else {
            return String(decoding: data, as: UTF8.self)
        }
        return str
    }

    @ViewBuilder
    private func statusPill(for status: PluginStatusEntry.Status) -> some View {
        switch status {
        case .loaded:
            Label("loaded", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .failed:
            Label("failed", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        }
    }

    /// Walks up from CWD AND `CommandLine.arguments[0]` to find the
    /// repo's `projects/plugins/plugins.json`. Mirror of the discovery
    /// pattern used by `PythonToolsPlugin.defaultRepoThirdpartyDir` —
    /// works under both `swift run` and from an installed
    /// `Infer.app` bundle (in the bundle case the plugins.json is
    /// also bundled, but for now we point at the repo source).
    private func revealPluginsJSONInFinder() {
        let starts: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: CommandLine.arguments.first ?? "/")
                .deletingLastPathComponent(),
            Bundle.main.bundleURL.deletingLastPathComponent(),
        ]
        for start in starts {
            var dir = start
            for _ in 0..<10 {
                let candidate = dir.appending(path: "projects/plugins/plugins.json")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([candidate])
                    return
                }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
        }
        // Couldn't locate it — fall back to opening the user's app
        // support dir (where future plugins.local.json would live).
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let support {
            NSWorkspace.shared.open(support.appending(path: "Infer", directoryHint: .isDirectory))
        }
    }
}
