import SwiftUI
import AppKit
import InferAgents
import InferCore

extension SidebarView {
    // MARK: History

    var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search conversations", text: Binding(
                get: { vm.vaultQuery },
                set: { vm.vaultQuery = $0; vm.scheduleVaultSearch() }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)

            tagFacet

            let isSearching = !vm.vaultQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if isSearching {
                if vm.vaultResults.isEmpty {
                    Text("No matches").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(vm.vaultResults) { hit in
                            VaultHitRow(hit: hit) { vm.loadVaultConversation(id: hit.conversationId) }
                        }
                    }
                }
            } else {
                if vm.vaultRecents.isEmpty {
                    Text("No saved conversations yet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.vaultRecents) { conv in
                            VaultConversationRow(
                                conv: conv,
                                onOpen: { vm.loadVaultConversation(id: conv.id) },
                                onDelete: { vm.deleteVaultConversation(id: conv.id) },
                                onAddTag: { vm.addTag($0, to: conv.id) },
                                onRemoveTag: { vm.removeTag($0, from: conv.id) },
                                onToggleTagFilter: { vm.toggleTagFilter($0) }
                            )
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Clear vault…") {
                    let alert = NSAlert()
                    alert.messageText = "Clear all saved conversations?"
                    alert.informativeText = "This removes every conversation in the vault and cannot be undone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Clear")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        vm.clearVault()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// Tag facet filter for History. Renders horizontally-scrolling
    /// chips for every tag in the vault; clicking toggles the chip's
    /// membership in `vm.vaultTagFilter`. AND-match, so multiple
    /// selected chips narrow the list. Hidden when no tags exist yet.
    @ViewBuilder
    var tagFacet: some View {
        if !vm.allVaultTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(vm.allVaultTags, id: \.self) { tag in
                        let selected = vm.vaultTagFilter.contains(
                            VaultStore.normalizeTag(tag)
                        )
                        Button {
                            vm.toggleTagFilter(tag)
                        } label: {
                            Text("#\(tag)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        selected
                                            ? Color.accentColor.opacity(0.2)
                                            : Color.secondary.opacity(0.1)
                                    )
                                )
                                .overlay(
                                    Capsule().stroke(
                                        selected
                                            ? Color.accentColor.opacity(0.5)
                                            : Color.secondary.opacity(0.25)
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    if !vm.vaultTagFilter.isEmpty {
                        Button("clear") { vm.clearTagFilter() }
                            .font(.caption2)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // Parameters card (sliders, seed, system prompt) moved to the
    // Settings window in P3 — see `Sources/Infer/Settings/
    // ModelParametersSettingsView.swift`. The sidebar's Model tab keeps
    // the *picker* (backend, model selection, GGUF directory) but the
    // sampling/prompt knobs are no longer here.
    //
    // Tools tab moved to the Settings window in P2 — see
    // `Sources/Infer/Settings/ToolsSettingsView.swift`. Quarto and
    // web-search subgroups, the section view, and the
    // `currentBackendLabel` helper live there now.

    // MARK: Model

    var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "cube.box", title: "Model")

            Picker("Backend", selection: $vm.backend) {
                ForEach(Backend.allCases) { b in
                    Text(b.label).tag(b)
                }
            }
            .pickerStyle(.segmented)
            .disabled(vm.isLoadingModel || vm.isGenerating)

            modelPicker

            TextField(
                vm.backend == .mlx
                    ? "HF repo id (empty = default)"
                    : ".gguf path, filename, or https:// URL",
                text: $vm.modelInput
            )
            .textFieldStyle(.roundedBorder)
            .disabled(vm.isLoadingModel || vm.isGenerating)
            .onSubmit { vm.loadCurrentBackend() }

            HStack(spacing: 6) {
                if vm.isLoadingModel {
                    Button(role: .cancel) { vm.cancelLoad() } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Button {
                        vm.loadCurrentBackend()
                    } label: {
                        Label("Load", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(vm.isGenerating)
                    if vm.backend == .llama {
                        Button {
                            vm.browseForLlamaModel()
                        } label: {
                            Label("Browse…", systemImage: "folder")
                        }
                        .disabled(vm.isGenerating)
                    }
                }
            }
            .buttonStyle(.bordered)

            if vm.backend == .llama {
                ggufDirectoryRow
            }
        }
        .onAppear { vm.refreshAvailableModelsIfNeeded() }
    }

    @ViewBuilder
    var modelPicker: some View {
        let entries = vm.availableModels
        Menu {
            if entries.isEmpty {
                Text("No downloaded models").foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.self) { entry in
                    Button {
                        vm.selectAvailableModel(entry)
                    } label: {
                        Text(SidebarView.dropdownLabel(for: entry))
                    }
                }
            }
        } label: {
            HStack {
                Text(modelPickerTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3))
        )
        .disabled(vm.isLoadingModel || vm.isGenerating)
    }

    var ggufDirectoryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GGUF folder").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(vm.resolvedGGUFDirectory.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Change…") { vm.pickGGUFDirectory() }
                    .controlSize(.small)
                if !vm.ggufDirectory.isEmpty {
                    Button("Reset") { vm.resetGGUFDirectory() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Migrated to Settings (P3)
    //
    // The Voice tab (`speechSection` + `whisperSubsection` +
    // `whisperModelMenu` + `voiceMenu` + `formatDuration`) and the
    // Appearance tab (`appearanceSection`) moved to the Settings
    // window in P3. See `Sources/Infer/Settings/VoiceSettingsView.swift`
    // and `Sources/Infer/Settings/AppearanceSettingsView.swift`.
}
