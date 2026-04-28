import SwiftUI

/// One row per compiled-in plugin (entries reflect what's in
/// `projects/plugins/plugins.json`). Loaded plugins show the tools
/// they contributed; failed plugins show the error message inline so
/// the user can act without digging through the Console scrollback.
struct PluginsSettingsView: View {
    let entries: [PluginStatusEntry]

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

    @ViewBuilder
    private func row(for entry: PluginStatusEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
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
            switch entry.status {
            case .loaded(let names) where !names.isEmpty:
                Text(names.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .loaded:
                Text("Plugin loaded but contributed no tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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
}
