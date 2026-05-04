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
    @State private var showPerToolOverrides = false

    /// Tools currently capable of honouring an output cap. Add a row
    /// here when migrating a new tool from a hardcoded byte limit to
    /// the `toolOutputCap(for:)` lookup. Pre-existing tools with their
    /// own limits stay until migrated.
    private static let cappableTools: [(name: String, label: String)] = [
        ("wikipedia.article", "Wikipedia article"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                outputLimitsGroup
                quartoGroup
                webSearchGroup
                Spacer(minLength: 0)
                HStack {
                    Button("Reset") {
                        let d = InferSettings.defaults
                        draft.quartoPath = d.quartoPath
                        draft.searxngEndpoint = d.searxngEndpoint
                        draft.toolOutputDefaultMaxBytes = d.toolOutputDefaultMaxBytes
                        draft.toolOutputOverrides = d.toolOutputOverrides
                    }
                    .controlSize(.small)
                    Spacer()
                    Button("Apply") { vm.applySettings(draft) }
                        .controlSize(.small)
                        .disabled(draftMatchesCurrent)
                }
            }
            .padding(16)
        }
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
            && s.toolOutputDefaultMaxBytes == draft.toolOutputDefaultMaxBytes
            && s.toolOutputOverrides == draft.toolOutputOverrides
    }

    /// Output cap controls. Global default applies to every tool that
    /// honours `toolOutputCap(for:)`; per-tool overrides expand from a
    /// foldable section below. `0` means "no cap" — surfaced as a
    /// distinct toggle so the slider doesn't have to span 0..∞.
    @ViewBuilder
    private var outputLimitsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output limits").font(.caption.weight(.semibold))
            Text("Cap on the bytes a tool can return to the model. Smaller values keep the chat context from blowing up after a verbose tool call (e.g. a Wikipedia article); larger values let the model see more.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ToolCapRow(
                label: "Default cap",
                bytes: $draft.toolOutputDefaultMaxBytes,
                allowsNoCap: false
            )

            DisclosureGroup(isExpanded: $showPerToolOverrides) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.cappableTools, id: \.name) { tool in
                        perToolRow(name: tool.name, label: tool.label)
                    }
                    Text("Tools not listed here use a hardcoded cap and will migrate as the codebase moves them onto the shared `toolOutputCap(for:)` lookup.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                Text("Per-tool overrides").font(.caption).foregroundStyle(.secondary)
            }
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
    private func perToolRow(name: String, label: String) -> some View {
        let isOverridden = draft.toolOutputOverrides[name] != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Text(name).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                Spacer()
                Toggle("Override", isOn: Binding(
                    get: { isOverridden },
                    set: { newValue in
                        if newValue {
                            draft.toolOutputOverrides[name] = draft.toolOutputDefaultMaxBytes
                        } else {
                            draft.toolOutputOverrides.removeValue(forKey: name)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            if isOverridden {
                ToolCapRow(
                    label: "Cap",
                    bytes: Binding(
                        get: { draft.toolOutputOverrides[name] ?? draft.toolOutputDefaultMaxBytes },
                        set: { draft.toolOutputOverrides[name] = $0 }
                    ),
                    allowsNoCap: true
                )
            } else {
                Text("Using default (\(byteLabel(draft.toolOutputDefaultMaxBytes)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func byteLabel(_ bytes: Int) -> String {
        if bytes == 0 { return "no cap" }
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        if bytes >= 1024 {
            return "\(bytes / 1024) KB"
        }
        return "\(bytes) B"
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

/// Slider + numeric readout for a byte cap. Range 1 KB ... 256 KB on a
/// log-ish step — fine-grained at the small end where local-model
/// context budget matters, coarser at the large end where the user is
/// just saying "give me a lot." `allowsNoCap` exposes a separate
/// toggle that maps to `0` (interpreted as `Int.max` by tools).
private struct ToolCapRow: View {
    let label: String
    @Binding var bytes: Int
    let allowsNoCap: Bool

    private static let stops: [Int] = [
        1024, 2048, 4096, 8192, 16_384, 32_768,
        65_536, 131_072, 262_144,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(displayLabel).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { Double(indexOfNearestStop(to: bytes)) },
                        set: { bytes = Self.stops[Int($0)] }
                    ),
                    in: 0...Double(Self.stops.count - 1),
                    step: 1
                )
                .disabled(allowsNoCap && bytes == 0)
                if allowsNoCap {
                    Toggle("No cap", isOn: Binding(
                        get: { bytes == 0 },
                        set: { newValue in
                            bytes = newValue ? 0 : Self.stops[4] // default to 16 KB
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
        }
    }

    private var displayLabel: String {
        if bytes == 0 { return "no cap" }
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        if bytes >= 1024 {
            return "\(bytes / 1024) KB"
        }
        return "\(bytes) B"
    }

    private func indexOfNearestStop(to value: Int) -> Int {
        if value <= 0 { return 0 }
        var bestIdx = 0
        var bestDiff = Int.max
        for (i, stop) in Self.stops.enumerated() {
            let diff = abs(stop - value)
            if diff < bestDiff {
                bestDiff = diff
                bestIdx = i
            }
        }
        return bestIdx
    }
}
