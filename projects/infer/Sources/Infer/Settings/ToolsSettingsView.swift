import SwiftUI
import InferCore

/// Per-tool configuration. Houses dependencies and credentials for
/// tools that aren't fully self-contained — today: Quarto's executable
/// path and the `web.search` backend selector. Future additions
/// (`http.fetch` host allowlist, `fs.read` allowed roots, MCP server
/// editor) belong here too.
///
/// Migrated from the sidebar's Tools tab in P2 of the Settings
/// migration. Same draft + Apply pattern as the sidebar version: a
/// local `InferSettings` copy is mutated, and `Apply` writes it to
/// `vm.settings` via `applySettings` (which is where the
/// re-registration of affected tools happens). This keeps a SearXNG
/// URL edit from re-registering on every keystroke.
struct ToolsSettingsView: View {
    @Bindable var vm: ChatViewModel
    @State private var draft: InferSettings = .defaults
    @State private var didSeed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            quartoGroup
            webSearchGroup
            Spacer(minLength: 0)
            HStack {
                Button("Reset") {
                    draft.quartoPath = InferSettings.defaults.quartoPath
                    draft.searxngEndpoint = InferSettings.defaults.searxngEndpoint
                }
                .controlSize(.small)
                Spacer()
                Button("Apply") { vm.applySettings(draft) }
                    .controlSize(.small)
                    .disabled(draftMatchesCurrent)
            }
        }
        .padding(16)
        .onAppear {
            if !didSeed {
                draft = vm.settings
                didSeed = true
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tools")
                .font(.title3.weight(.semibold))
            Text("Per-tool configuration. Changes take effect when you click Apply — no re-registration on each keystroke.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Only the fields exposed in this tab participate in the
    // change-detection — sampling / prompt fields edited elsewhere
    // (Model parameters in P3) shouldn't disable Apply here.
    private var draftMatchesCurrent: Bool {
        let s = vm.settings
        return (s.quartoPath ?? "") == (draft.quartoPath ?? "")
            && (s.searxngEndpoint ?? "") == (draft.searxngEndpoint ?? "")
    }

    @ViewBuilder
    private var quartoGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quarto").font(.caption.weight(.semibold))
            Text("Used by the **Quarto renderer** agent (`builtin.quarto.render`) to convert markdown to HTML, PDF, DOCX, slides, etc. Renders use the executable found below — leave the field empty to auto-detect.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            QuartoSettingsRow(
                path: Binding(
                    get: { draft.quartoPath ?? "" },
                    set: { s in
                        let trimmed = s.trimmingCharacters(in: .whitespaces)
                        draft.quartoPath = trimmed.isEmpty ? nil : trimmed
                    }
                )
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15))
        )
    }

    @ViewBuilder
    private var webSearchGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Web search").font(.caption.weight(.semibold))
                Spacer()
                Text(currentBackendLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Used by `web.search`. Default is **DuckDuckGo** HTML scraping (no setup; fragile to DDG layout changes). Optionally point at a **SearXNG** instance below for a robust JSON-API backend.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("https://searx.example.org", text: Binding(
                    get: { draft.searxngEndpoint ?? "" },
                    set: { s in
                        let trimmed = s.trimmingCharacters(in: .whitespaces)
                        draft.searxngEndpoint = trimmed.isEmpty ? nil : trimmed
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.caption.monospaced())

                Button("Clear") {
                    draft.searxngEndpoint = nil
                }
                .controlSize(.small)
                .disabled((draft.searxngEndpoint ?? "").isEmpty)
            }
            Text("Empty = use DuckDuckGo. The endpoint should be the SearXNG instance's base URL (the tool appends `/search?format=json`).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15))
        )
    }

    private var currentBackendLabel: String {
        let raw = (draft.searxngEndpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "DuckDuckGo" : "SearXNG"
    }
}
