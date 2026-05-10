import SwiftUI
import AppKit
import InferAgents

/// Inline workspace settings — name, data folder, RAG status, retrieval
/// toggles, stats, delete — surfaced as collapsible disclosures inside
/// `WikiSidebar`. Replaces the modal `WorkspaceSheet` for the editing
/// path; creation still goes through the modal because the
/// "name a new thing" flow is a single decision point that benefits
/// from focus.
///
/// Saves are explicit (Apply button per section) rather than per-
/// keystroke so partial edits don't churn the vault. The state lives
/// locally and is reseeded any time the active workspace changes;
/// dirty state is exposed via `hasPendingNameOrFolder` so the Apply
/// button can be disabled when nothing has changed.
struct WorkspaceSettingsInline: View {
    @Bindable var vm: ChatViewModel
    let workspace: WorkspaceSummary

    /// Section open/closed state — persisted via @AppStorage so the
    /// user's last fold state survives relaunch.
    @AppStorage("infer.wiki.sidebar.fold.workspace") private var workspaceFoldOpen: Bool = true
    @AppStorage("infer.wiki.sidebar.fold.rag") private var ragFoldOpen: Bool = false

    @State private var name: String = ""
    @State private var dataFolder: String = ""
    @State private var outputDirectory: String = ""
    @State private var seededWorkspaceId: Int64 = -1
    @State private var confirmDelete: Bool = false
    @State private var confirmReset: Bool = false
    @State private var availableAgentsOpen: Bool = false
    @State private var availableToolsOpen: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            workspaceDisclosure
            ragDisclosure
        }
        .onAppear { seedFields(force: false) }
        .onChange(of: workspace.id) { _, _ in seedFields(force: true) }
    }

    // MARK: - Disclosures

    private var workspaceDisclosure: some View {
        DisclosureGroup(isExpanded: $workspaceFoldOpen) {
            VStack(alignment: .leading, spacing: 8) {
                nameField
                dataFolderField
                outputDirectoryField
                availableAgentsDisclosure
                availableToolsDisclosure
                metadataRow
                deleteRow
            }
            .padding(.top, 4)
        } label: {
            Text("Workspace")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .alert("Delete workspace?",
               isPresented: $confirmDelete,
               actions: {
                   Button("Delete", role: .destructive) {
                       vm.deleteWorkspace(id: workspace.id)
                   }
                   Button("Cancel", role: .cancel) {}
               },
               message: {
                   Text("Conversations assigned to this workspace will become unassigned (they stay in History). RAG sources for this workspace will need to be re-ingested into a new workspace.")
               })
    }

    private var ragDisclosure: some View {
        DisclosureGroup(isExpanded: $ragFoldOpen) {
            VStack(alignment: .leading, spacing: 8) {
                embeddingModelStatus
                if !dataFolder.isEmpty {
                    scanSection
                }
                retrievalTogglesSection
            }
            .padding(.top, 4)
        } label: {
            Text("RAG corpus")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Workspace fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Name").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("Workspace name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .disabled(vm.isDefaultWorkspace(workspace.id))
                    .onSubmit { applyNameIfChanged() }
                Button("Apply") { applyNameIfChanged() }
                    .controlSize(.small)
                    .disabled(!isNameDirty || vm.isDefaultWorkspace(workspace.id))
            }
            if vm.isDefaultWorkspace(workspace.id) {
                Text("The Default workspace can't be renamed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var dataFolderField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Data folder").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("No folder set", text: $dataFolder)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { applyDataFolderIfChanged() }
                Button {
                    if let url = FileDialogs.openDirectory(
                        message: "Choose a folder whose files will be ingested into this workspace's RAG corpus"
                    ) {
                        dataFolder = url.path
                        applyDataFolderIfChanged()
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .help("Choose folder")
                if !dataFolder.isEmpty {
                    Button {
                        dataFolder = ""
                        applyDataFolderIfChanged()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear folder")
                }
            }
            if isDataFolderDirty {
                Button("Apply folder change") { applyDataFolderIfChanged() }
                    .controlSize(.small)
                    .font(.caption2)
            }
        }
    }

    /// Per-workspace override for where generated artifacts (Stable
    /// Diffusion images today; transcript exports later) are written.
    /// Empty = inherit from Default's row, or — when Default also
    /// hasn't set a path — fall back to the legacy
    /// `Application Support/Infer/Generated Images/` location. The
    /// placeholder always shows the currently-effective path so the
    /// user can tell what they're departing from. Tilde-paths are
    /// preserved as authored; expansion happens in
    /// `effectiveOutputDirectory`.
    private var outputDirectoryField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Output directory").font(.caption2).foregroundStyle(.secondary)
                if isOverridingOutputDirectory {
                    Button {
                        outputDirectory = ""
                        applyOutputDirectoryIfChanged()
                    } label: {
                        Label("Default", systemImage: "arrow.uturn.backward")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .foregroundStyle(.secondary)
                    .help("Clear this workspace's override; falls back to the path shown in the placeholder.")
                }
            }
            HStack(spacing: 4) {
                TextField(effectiveOutputDirectoryPlaceholder, text: $outputDirectory)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { applyOutputDirectoryIfChanged() }
                Button {
                    if let url = FileDialogs.openDirectory(
                        message: "Choose where this workspace's generated images should be written"
                    ) {
                        outputDirectory = url.path
                        applyOutputDirectoryIfChanged()
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .help("Choose folder")
            }
            if isOutputDirectoryDirty {
                Button("Apply output directory") { applyOutputDirectoryIfChanged() }
                    .controlSize(.small)
                    .font(.caption2)
            }
        }
    }

    /// Per-workspace allow-list of agents visible in the picker /
    /// library for THIS workspace. Phase 4a of per-workspace-params.
    /// Collapsed by default — most users don't need to curate this
    /// per-workspace, and unfolding it surfaces the full agent
    /// catalogue which is long.
    ///
    /// Layout: header summarises current state (`(allow-list active)`
    /// / `(inheriting Default)` / `(everything available)`), with a
    /// `↺ Default` button when this row's `enabled_agents` column
    /// is non-NULL. The unfolded body lists every known agent with
    /// a checkbox; toggling fires `vm.toggleAgentInAllowList`,
    /// which materialises an explicit list on first toggle (so
    /// flipping a single switch produces "everything except this"
    /// rather than "only this").
    @ViewBuilder
    private var availableAgentsDisclosure: some View {
        DisclosureGroup(isExpanded: $availableAgentsOpen) {
            availableAgentsBody
        } label: {
            HStack(spacing: 6) {
                Text("Available agents").font(.caption2).foregroundStyle(.secondary)
                Text(availableAgentsSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if workspace.enabledAgents != nil {
                    Button {
                        vm.setWorkspaceEnabledAgents(id: workspace.id, ids: nil)
                    } label: {
                        Label("Default", systemImage: "arrow.uturn.backward")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .foregroundStyle(.secondary)
                    .help("Clear this workspace's allow-list; falls back to the Default workspace's list.")
                }
                Spacer()
            }
        }
    }

    private var availableAgentsBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(vm.availableAgents) { listing in
                let agentId = listing.id
                let isEnabled: Bool = {
                    if let allow = workspace.enabledAgents {
                        return allow.contains(agentId.rawValue)
                    }
                    // No override on this row → effective is the
                    // cascade fall-through. The toggle still
                    // shows accurately by reading the resolved
                    // allow-list at the consumer level.
                    return vm.isAgentEnabledInActiveWorkspace(agentId)
                }()
                let isDefaultAgent = (agentId == DefaultAgent.id)
                Toggle(isOn: Binding(
                    get: { isEnabled },
                    set: { _ in
                        vm.toggleAgentInAllowList(workspaceId: workspace.id, agentId: agentId)
                    }
                )) {
                    HStack(spacing: 6) {
                        Text(listing.name).font(.caption)
                        if isDefaultAgent {
                            Text("(always available)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(isDefaultAgent) // safety net — can't be toggled off
                .help(isDefaultAgent
                    ? "DefaultAgent is always available — the safety net so you can never lock yourself out of a workspace."
                    : listing.description)
            }
            if vm.availableAgents.isEmpty {
                Text("No agents loaded.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }

    /// Per-workspace allow-list of tools available to the active
    /// agent. Phase 4b — sibling of `availableAgentsDisclosure`.
    /// Same rendering shape: collapsed by default, header summary,
    /// `↺ Default` button when this row's `enabled_tools` column
    /// is non-NULL. Body lists every tool currently in the registry
    /// (`vm.availableToolNames`, snapshotted onAppear so MCP-
    /// discovered tools that register at runtime are visible) with
    /// per-row checkboxes. **No safety net** — DefaultAgent stays
    /// available even when every tool is silenced; the empty list
    /// is a legitimate "no tools" workspace shape.
    @ViewBuilder
    private var availableToolsDisclosure: some View {
        DisclosureGroup(isExpanded: $availableToolsOpen) {
            availableToolsBody
        } label: {
            HStack(spacing: 6) {
                Text("Available tools").font(.caption2).foregroundStyle(.secondary)
                Text(availableToolsSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if workspace.enabledTools != nil {
                    Button {
                        vm.setWorkspaceEnabledTools(id: workspace.id, ids: nil)
                    } label: {
                        Label("Default", systemImage: "arrow.uturn.backward")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .foregroundStyle(.secondary)
                    .help("Clear this workspace's tool allow-list; falls back to the Default workspace's list.")
                }
                Spacer()
            }
        }
    }

    private var availableToolsBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if vm.availableToolNames.isEmpty {
                Text("No tools registered yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(vm.availableToolNames, id: \.self) { name in
                    let isEnabled: Bool = {
                        if let allow = workspace.enabledTools {
                            return allow.contains(name)
                        }
                        return vm.isToolEnabledInActiveWorkspace(name)
                    }()
                    Toggle(isOn: Binding(
                        get: { isEnabled },
                        set: { _ in
                            vm.toggleToolInAllowList(
                                workspaceId: workspace.id,
                                toolName: name,
                                universe: vm.availableToolNames
                            )
                        }
                    )) {
                        Text(name)
                            .font(.caption.monospaced())
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }
        }
        .padding(.top, 4)
    }

    private var availableToolsSummary: String {
        if let allow = workspace.enabledTools {
            return "(\(allow.count) allowed)"
        }
        if vm.isDefaultWorkspace(workspace.id) {
            return "(everything available)"
        }
        return "(inheriting Default)"
    }

    /// One-liner status the disclosure header shows next to the
    /// title so the user can tell at a glance whether their
    /// workspace overrides the list or inherits.
    private var availableAgentsSummary: String {
        if let allow = workspace.enabledAgents {
            // Explicit list on this row.
            let count = allow.count
            return "(\(count) allowed)"
        }
        // Inheriting from the cascade. Distinguish "this is Default
        // and inherits 'everything'" from "this is non-Default and
        // inherits Default's list."
        if vm.isDefaultWorkspace(workspace.id) {
            return "(everything available)"
        }
        return "(inheriting Default)"
    }

    private var metadataRow: some View {
        HStack(spacing: 12) {
            metaLabel(key: "id", value: "\(workspace.id)")
            metaLabel(key: "conv", value: "\(workspace.conversationCount)")
            metaLabel(key: "created", value: formatted(workspace.createdAt))
        }
    }

    @ViewBuilder
    private var deleteRow: some View {
        if vm.isDefaultWorkspace(workspace.id) {
            // Default workspace: not deletable, but the user can reset
            // its inference parameters (system prompt, temperature,
            // top-p, max tokens) back to the app's hard-coded
            // defaults. Wiki pages, RAG corpus, conversations, and
            // the data folder setting are preserved — reset is now
            // narrowly scoped to params.
            Button {
                confirmReset = true
            } label: {
                Label("Reset parameters", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .font(.caption)
            .alert("Reset parameters to defaults?",
                   isPresented: $confirmReset,
                   actions: {
                       Button("Reset", role: .destructive) {
                           vm.resetWorkspace(id: workspace.id)
                       }
                       Button("Cancel", role: .cancel) {}
                   },
                   message: {
                       Text("Clears any per-workspace overrides for system prompt, temperature, top-p, and max tokens. Wiki pages, RAG corpus, conversations, and the data folder setting stay.")
                   })
        } else {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete workspace", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.red)
        }
    }

    // MARK: - RAG fields

    @ViewBuilder
    private var embeddingModelStatus: some View {
        if vm.embeddingModelDownloading {
            ModelDownloadStatus(state: .downloading(
                name: EmbeddingModelRef.displayName,
                progress: vm.embeddingModelDownloadProgress
            ))
        } else if !vm.embeddingModelPresent {
            ModelDownloadStatus(state: .missing(
                title: "Embedding model missing",
                description: "RAG requires the `\(EmbeddingModelRef.displayName)` model (≈130 MB).",
                ctaLabel: "Download",
                action: { vm.downloadEmbeddingModel() }
            ))
        } else {
            ModelDownloadStatus(state: .ready(
                label: "Embedding ready: \(EmbeddingModelRef.displayName)"
            ))
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        if let progress = vm.ingestProgress, progress.workspaceId == workspace.id {
            ingestProgressView(progress)
        } else {
            HStack(spacing: 6) {
                Button {
                    vm.scanAndIngest(workspaceId: workspace.id)
                } label: {
                    Label("Scan folder", systemImage: "doc.text.magnifyingglass")
                }
                .controlSize(.small)
                .disabled(!(vm.embeddingModelPresent && !vm.embeddingModelDownloading))
                Spacer()
            }
            if let stats = vm.corpusStats, stats.workspaceId == workspace.id, stats.sources > 0 {
                Text("\(stats.sources) source\(stats.sources == 1 ? "" : "s") · \(stats.chunks) chunk\(stats.chunks == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var retrievalTogglesSection: some View {
        let hydeBinding = Binding<Bool>(
            get: { vm.workspaceSetting(.hydeEnabled, workspaceId: workspace.id) },
            set: { vm.setWorkspaceSetting(.hydeEnabled, workspaceId: workspace.id, $0) }
        )
        let rerankBinding = Binding<Bool>(
            get: { vm.workspaceSetting(.rerankEnabled, workspaceId: workspace.id) },
            set: { vm.setWorkspaceSetting(.rerankEnabled, workspaceId: workspace.id, $0) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Reformulate queries (HyDE)", isOn: hydeBinding)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Before retrieval, the chat model writes a hypothetical answer; that answer is embedded instead of the raw question. Adds ~1 s per query.")
            Toggle("Rerank results", isOn: rerankBinding)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(!vm.rerankerModelPresent)
                .help("Fetches 30 candidate chunks, re-scores with bge-reranker-v2-m3 cross-encoder, returns top 5. Adds ~1–2 s per query.")
            if rerankBinding.wrappedValue || !vm.rerankerModelPresent {
                rerankerModelStatus
            }
        }
    }

    @ViewBuilder
    private var rerankerModelStatus: some View {
        if vm.rerankerModelDownloading {
            ModelDownloadStatus(state: .downloading(
                name: RerankerModelRef.displayName,
                progress: vm.rerankerModelDownloadProgress
            ))
        } else if !vm.rerankerModelPresent {
            ModelDownloadStatus(state: .missing(
                title: "Reranker model missing",
                description: "Rerank requires `\(RerankerModelRef.displayName)` (≈315 MB).",
                ctaLabel: "Download",
                action: { vm.downloadRerankerModel() }
            ))
        } else {
            ModelDownloadStatus(state: .ready(label: "Reranker ready"))
        }
    }

    @ViewBuilder
    private func ingestProgressView(_ progress: IngestProgress) -> some View {
        let frac: Double = progress.totalFiles > 0
            ? Double(progress.processedFiles) / Double(progress.totalFiles)
            : 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Scanning \(progress.processedFiles)/\(progress.totalFiles)")
                    .font(.caption)
                Spacer()
            }
            ProgressView(value: frac).progressViewStyle(.linear)
            if let file = progress.currentFile {
                Text(file)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Helpers

    private var isNameDirty: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != workspace.name
    }

    private var isDataFolderDirty: Bool {
        let value = dataFolder.isEmpty ? nil : dataFolder
        return value != workspace.dataFolder
    }

    private var isOutputDirectoryDirty: Bool {
        let value = outputDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.isEmpty ? nil : value
        return normalized != workspace.outputDirectory
    }

    /// True when this workspace's `output_directory` column is
    /// non-NULL — i.e. there's a stored override the `Default` button
    /// would clear. Distinct from `isOutputDirectoryDirty` (which
    /// compares the in-flight TextField buffer to the saved value).
    private var isOverridingOutputDirectory: Bool {
        workspace.outputDirectory != nil
    }

    /// What the `outputDirectory` field should show as a placeholder
    /// when empty — the path the next generation would actually use
    /// if this workspace doesn't override. Looks up the cascade
    /// without the active workspace layer (so the placeholder shows
    /// what falls through, regardless of which workspace is active).
    private var effectiveOutputDirectoryPlaceholder: String {
        // Default's row first; legacy fallback otherwise.
        if let row = vm.workspaces.min(by: { $0.id < $1.id }),
           row.id != workspace.id,
           let v = row.outputDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !v.isEmpty
        {
            return "Default: \(v)"
        }
        return ChatViewModel.legacyOutputDirectory().path
    }

    private func applyNameIfChanged() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workspace.name else { return }
        vm.renameWorkspace(id: workspace.id, to: trimmed)
    }

    private func applyDataFolderIfChanged() {
        let value = dataFolder.isEmpty ? nil : dataFolder
        guard value != workspace.dataFolder else { return }
        vm.setWorkspaceDataFolder(id: workspace.id, dataFolder: value)
        vm.refreshCorpusStats(workspaceId: workspace.id)
    }

    private func applyOutputDirectoryIfChanged() {
        let trimmed = outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? nil : trimmed
        guard normalized != workspace.outputDirectory else { return }
        vm.setWorkspaceOutputDirectory(id: workspace.id, path: normalized)
    }

    private func seedFields(force: Bool) {
        if force || seededWorkspaceId != workspace.id {
            name = workspace.name
            dataFolder = workspace.dataFolder ?? ""
            outputDirectory = workspace.outputDirectory ?? ""
            seededWorkspaceId = workspace.id
            vm.refreshCorpusStats(workspaceId: workspace.id)
            // Refresh the tool catalogue snapshot so the
            // "Available tools" disclosure shows the current
            // registry — MCP tools register / unregister at
            // runtime, so a snapshot from VM-init time would go
            // stale.
            vm.refreshAvailableToolNames()
        }
    }

    private func metaLabel(key: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(key).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
        .font(.caption2.monospaced())
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: date)
    }
}
