import SwiftUI
import AppKit
import InferAgents

/// Read-only detail sheet for an agent listing. Shows system prompt,
/// tool exposure, decoding overrides, compatibility, and source actions.
/// Two entry points: the "View details" menu item on any library row,
/// and the fallback for tap-on-incompatible-row (so the user learns the
/// reason without the row silently doing nothing).
///
/// Intentionally read-only. Authoring still happens in JSON — this view
/// is for verifying what a persona will do *before* activating it. The
/// `Preview change` section offers a textual summary of what switching
/// will change relative to the currently-active agent.
struct AgentInspectorView: View {
    let vm: ChatViewModel
    let listing: AgentListing
    let dismiss: () -> Void

    @State private var snapshot: ChatViewModel.AgentSnapshot?
    @State private var activeSnapshot: ChatViewModel.AgentSnapshot?
    @State private var showPreview: Bool = false

    private var isActive: Bool { listing.id == vm.activeAgentId }
    private var isCompatible: Bool { vm.isCompatible(listing) }
    private var isUserPersona: Bool {
        listing.source == .user && !listing.isDefault
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let snap = snapshot {
                        metadataSection(snap)
                        systemPromptSection(snap)
                        // Personas can never expose tools (runtime guarantee
                        // in `PromptAgent.toolsAvailable`), and their
                        // backend compatibility is meaningful only via the
                        // template-family check that lands in M4 — until
                        // then, hiding both sections keeps the inspector
                        // honest about what a persona actually controls.
                        if listing.kind == .agent {
                            toolsSection(snap)
                        }
                        decodingSection(snap)
                        if listing.kind == .agent {
                            compatibilitySection
                        }
                        if showPreview, let active = activeSnapshot, !isActive {
                            previewSection(from: active, to: snap)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 440, idealWidth: 500, minHeight: 380, idealHeight: 560)
        .task {
            snapshot = await vm.inspectorSnapshot(for: listing)
            if let active = vm.activeAgentListing {
                activeSnapshot = await vm.inspectorSnapshot(for: active)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(listing.name)
                        .font(.title3).fontWeight(.semibold)
                    if isActive {
                        Text("active")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                Text(sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", action: dismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func metadataSection(_ snap: ChatViewModel.AgentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !listing.description.isEmpty {
                Text(listing.description)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func systemPromptSection(_ snap: ChatViewModel.AgentSnapshot) -> some View {
        SectionLabel("System prompt")
        if let prompt = snap.systemPrompt, !prompt.isEmpty {
            ScrollView {
                Text(prompt)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15))
            )
        } else {
            Text(listing.isDefault
                ? "No system prompt set. Edit it in the Model tab."
                : "This agent provides its prompt dynamically or has no stored prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func toolsSection(_ snap: ChatViewModel.AgentSnapshot) -> some View {
        SectionLabel("Tools")
        if snap.exposedTools.isEmpty {
            Text(listing.isDefault
                ? "The default agent does not call tools."
                : "No tools exposed to this agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(snap.exposedTools, id: \.name) { tool in
                    HStack(alignment: .top, spacing: 6) {
                        Text(tool.name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                        if !tool.description.isEmpty {
                            Text("— \(tool.description)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !snap.toolsAllow.isEmpty {
                    Text("allow-list: \(snap.toolsAllow.joined(separator: ", "))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                if !snap.toolsDeny.isEmpty {
                    Text("deny-list: \(snap.toolsDeny.joined(separator: ", "))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func decodingSection(_ snap: ChatViewModel.AgentSnapshot) -> some View {
        SectionLabel("Decoding")
        let base = DecodingParams(from: vm.settings)
        let diffs = DecodingParams.describe(snap.decoding, comparedTo: base)
        if diffs.isEmpty {
            Text("Uses the default settings (no overrides).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(diffs, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    @ViewBuilder
    private var compatibilitySection: some View {
        SectionLabel("Compatibility")
        HStack(spacing: 6) {
            Image(systemName: isCompatible ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isCompatible ? .green : .orange)
            Text(isCompatible
                ? "Compatible with the current backend (\(vm.backend.label))."
                : vm.incompatibilityReason(listing))
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func previewSection(
        from active: ChatViewModel.AgentSnapshot,
        to target: ChatViewModel.AgentSnapshot
    ) -> some View {
        SectionLabel("Switch preview")
        let lines = DecodingParams.describe(target.decoding, comparedTo: active.decoding)
        let addedTools = target.exposedTools
            .map(\.name)
            .filter { name in !active.exposedTools.contains(where: { $0.name == name }) }
        let removedTools = active.exposedTools
            .map(\.name)
            .filter { name in !target.exposedTools.contains(where: { $0.name == name }) }
        let promptChanged = (active.systemPrompt ?? "") != (target.systemPrompt ?? "")
        VStack(alignment: .leading, spacing: 4) {
            if promptChanged {
                Text("• System prompt will change.")
                    .font(.caption)
            }
            if !addedTools.isEmpty {
                Text("• Tools added: \(addedTools.joined(separator: ", "))")
                    .font(.caption)
            }
            if !removedTools.isEmpty {
                Text("• Tools removed: \(removedTools.joined(separator: ", "))")
                    .font(.caption)
            }
            ForEach(lines, id: \.self) { line in
                Text("• \(line)").font(.caption)
            }
            if !promptChanged && addedTools.isEmpty && removedTools.isEmpty && lines.isEmpty {
                Text("No user-visible differences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.25))
        )
    }

    // MARK: - Footer actions

    private var footer: some View {
        HStack(spacing: 8) {
            if isUserPersona, let url = vm.userPersonaURL(for: listing.id) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal JSON", systemImage: "folder")
                }
                .controlSize(.small)
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Edit JSON", systemImage: "square.and.pencil")
                }
                .controlSize(.small)
            }
            if !listing.isDefault {
                Button {
                    Task { await vm.duplicatePersona(listing) }
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            Spacer()
            if !isActive {
                Button {
                    showPreview.toggle()
                } label: {
                    Label(showPreview ? "Hide preview" : "Preview change", systemImage: "arrow.left.arrow.right")
                }
                .controlSize(.small)
                .disabled(!isCompatible)

                Button("Activate") {
                    vm.switchAgent(to: listing)
                    dismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(!isCompatible)
                .help(isCompatible
                      ? "Make this the active agent for the conversation."
                      : vm.incompatibilityReason(listing))
            }
        }
        .padding(12)
    }

    // MARK: - Helpers

    private var sourceLabel: String {
        let src: String
        switch listing.source {
        case .user: src = "User persona"
        case .plugin: src = "Plugin persona"
        case .firstParty: src = listing.isDefault ? "Built-in" : "First-party persona"
        }
        if let fam = listing.templateFamily { return "\(src) · template: \(fam.rawValue)" }
        return src
    }
}

/// Section label reused across inspector panels. Small caps style to
/// read as structural chrome, not content.
private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

extension DecodingParams {
    /// Produce human-readable lines describing how `target` differs from
    /// `base`. Empty array means no differences. Used by the inspector's
    /// Decoding and Preview sections.
    static func describe(_ target: DecodingParams, comparedTo base: DecodingParams) -> [String] {
        var lines: [String] = []
        if target.temperature != base.temperature {
            lines.append(String(format: "temperature: %.2f → %.2f", base.temperature, target.temperature))
        }
        if target.topP != base.topP {
            lines.append(String(format: "topP: %.2f → %.2f", base.topP, target.topP))
        }
        if target.maxTokens != base.maxTokens {
            lines.append("maxTokens: \(base.maxTokens) → \(target.maxTokens)")
        }
        return lines
    }
}
