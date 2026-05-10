import SwiftUI
import AppKit
import InferAgents

/// Workspace settings sheet — modal panel opened from the cog button
/// in the wiki sidebar's footer. Tabbed into three sections: General
/// (identity + storage + reset/delete), Agents & Tools (the three
/// Phase 4 allow-lists), and RAG (corpus controls). For the Default
/// workspace the panel edits the global floor (name disabled,
/// "delete" replaced by a parameter-reset button); for other
/// workspaces it edits that workspace's overrides + identity.
///
/// Phase 1 inference parameters (system prompt, temperature, top-p,
/// max tokens) are deliberately NOT in this panel — they stay in the
/// right-sidebar Parameters disclosure where the user adjusts them
/// during a session. This panel is the workspace-identity surface,
/// not the runtime-tuning one.
///
/// Replaces the prior inline-disclosure embedding in `WikiSidebar`'s
/// scroll view (file kept at the same path for git-history
/// continuity; struct renamed).
struct WorkspaceSettingsSheet: View {
    @Bindable var vm: ChatViewModel
    let workspace: WorkspaceSummary
    @Binding var isPresented: Bool

    @State private var selectedTab: Tab = .general
    @State private var name: String = ""
    @State private var dataFolder: String = ""
    @State private var outputDirectory: String = ""
    @State private var seededWorkspaceId: Int64 = -1
    @State private var confirmDelete: Bool = false
    @State private var confirmReset: Bool = false
    // (Phase 4 disclosure-fold state removed — each allow-list now
    //  has its own tab in the workspace settings sheet, so the
    //  inline collapsibility is redundant.)

    enum Tab: String, CaseIterable, Identifiable {
        case general
        case agents
        case tools
        case mcpServers
        case rag
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return "General"
            case .agents: return "Agents"
            case .tools: return "Tools"
            case .mcpServers: return "MCP"
            case .rag: return "RAG"
            }
        }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .agents: return "person.crop.circle"
            case .tools: return "wrench.and.screwdriver"
            case .mcpServers: return "server.rack"
            case .rag: return "doc.text.magnifyingglass"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            ScrollView {
                tabContent
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480, idealHeight: 560)
        .onAppear { seedFields(force: false) }
        .onChange(of: workspace.id) { _, _ in seedFields(force: true) }
        .alert("Delete workspace?",
               isPresented: $confirmDelete,
               actions: {
                   Button("Delete", role: .destructive) {
                       vm.deleteWorkspace(id: workspace.id)
                       isPresented = false
                   }
                   Button("Cancel", role: .cancel) {}
               },
               message: {
                   Text("Conversations assigned to this workspace will become unassigned (they stay in History). RAG sources for this workspace will need to be re-ingested into a new workspace.")
               })
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(vm.isDefaultWorkspace(workspace.id) ? "Default workspace settings" : "Workspace settings")
                    .font(.headline)
                Text(workspace.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                        Text(tab.label)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general: generalTab
        case .agents: agentsTab
        case .tools: toolsTab
        case .mcpServers: mcpServersTab
        case .rag: ragTab
        }
    }

    // MARK: - Tabs

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            nameField
            dataFolderField
            outputDirectoryField
            Divider()
            metadataRow
            deleteRow
        }
    }

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            AllowListStatusBanner(
                title: agentsBannerTitle,
                detail: agentsBannerDetail,
                isOverriding: workspace.enabledAgents != nil,
                onClearOverride: { vm.setWorkspaceEnabledAgents(id: workspace.id, ids: nil) }
            )
            agentsToggleList
        }
    }

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            AllowListStatusBanner(
                title: toolsBannerTitle,
                detail: toolsBannerDetail,
                isOverriding: workspace.enabledTools != nil,
                onClearOverride: { vm.setWorkspaceEnabledTools(id: workspace.id, ids: nil) }
            )
            toolsToggleList
        }
    }

    private var mcpServersTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            AllowListStatusBanner(
                title: mcpServersBannerTitle,
                detail: mcpServersBannerDetail,
                isOverriding: workspace.enabledMCPServers != nil,
                onClearOverride: { vm.setWorkspaceEnabledMCPServers(id: workspace.id, ids: nil) }
            )
            mcpServersToggleList
        }
    }

    private var ragTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            embeddingModelStatus
            if !dataFolder.isEmpty {
                scanSection
            }
            retrievalTogglesSection
        }
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

    /// Per-row toggle grid for the Phase 4a agents allow-list.
    /// Banner above the grid (`AllowListStatusBanner` driven by
    /// `agentsBannerTitle` / `agentsBannerDetail`) communicates the
    /// effective state and offers a clear-override action;
    /// previously this was a cryptic `(N allowed)` chip on a
    /// disclosure header. Toggling a row fires
    /// `vm.toggleAgentInAllowList`, which materialises an explicit
    /// list on first toggle (so flipping a single switch produces
    /// "everything except this" rather than "only this").
    private var agentsToggleList: some View {
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

    /// Per-row toggle grid for the Phase 4b tools allow-list.
    /// Same flat shape as `agentsToggleList`. Universe is whatever
    /// tools are currently in the registry (`vm.availableToolNames`,
    /// snapshotted at `bootstrapAgents` end and re-snapshotted on
    /// sheet appear so MCP-discovered tools register-at-runtime
    /// show up).
    private var toolsToggleList: some View {
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

    /// Per-row toggle grid for the Phase 4c MCP server allow-list.
    /// Same flat shape as `agentsToggleList` / `toolsToggleList`.
    private var mcpServersToggleList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if vm.mcpServers.isEmpty {
                Text("No MCP servers configured.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(vm.mcpServers) { server in
                    let isEnabled: Bool = {
                        if let allow = workspace.enabledMCPServers {
                            return allow.contains(server.id)
                        }
                        return vm.isMCPServerEnabledInActiveWorkspace(server.id)
                    }()
                    let universe = vm.mcpServers.map(\.id)
                    Toggle(isOn: Binding(
                        get: { isEnabled },
                        set: { _ in
                            vm.toggleMCPServerInAllowList(
                                workspaceId: workspace.id,
                                serverID: server.id,
                                universe: universe
                            )
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.displayName).font(.caption)
                            Text(server.id)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Banner state strings
    //
    // Each tab's banner reads from its workspace column and the
    // active workspace's id-vs-Default check. `enabledX != nil`
    // means an explicit override is stored (possibly the empty
    // array for "silenced"); `enabledX == nil` means the cascade
    // falls through. The wording deliberately spells out what's
    // happening — replaces the old `(N allowed)` chip that left
    // users guessing what state they were in.

    private var agentsBannerTitle: String {
        if let allow = workspace.enabledAgents {
            if allow.isEmpty {
                return "Only DefaultAgent available"
            }
            return "\(allow.count) of \(vm.availableAgents.count) agents available"
        }
        if vm.isDefaultWorkspace(workspace.id) {
            return "All agents available"
        }
        return "Inheriting from Default"
    }

    private var agentsBannerDetail: String {
        if let allow = workspace.enabledAgents {
            if allow.isEmpty {
                return "This workspace silences every agent. DefaultAgent stays available — it's the safety net so you can never lock yourself out."
            }
            return "This workspace overrides the Default workspace's agent list. Toggle agents below to edit; click Use Default to clear."
        }
        if vm.isDefaultWorkspace(workspace.id) {
            return "Default workspace inherits no further. Toggling any agent below starts an explicit list — the safety net keeps DefaultAgent always on."
        }
        return "Falling back to the Default workspace's list. Toggle any agent below to start customizing this workspace."
    }

    private var toolsBannerTitle: String {
        if let allow = workspace.enabledTools {
            if allow.isEmpty {
                return "No tools available"
            }
            return "\(allow.count) of \(vm.availableToolNames.count) tools available"
        }
        if vm.isDefaultWorkspace(workspace.id) {
            return "All tools available"
        }
        return "Inheriting from Default"
    }

    private var toolsBannerDetail: String {
        if let allow = workspace.enabledTools {
            if allow.isEmpty {
                return "Workspace-silenced — the active agent will see no tools in its prompt. Legitimate for security-sensitive contexts."
            }
            return "This workspace overrides the Default workspace's tool list. Tools whose owning MCP server is disabled (in the MCP tab) are also subtracted — composition is automatic."
        }
        if vm.isDefaultWorkspace(workspace.id) {
            return "Default workspace inherits no further. Toggling any tool below starts an explicit list."
        }
        return "Falling back to the Default workspace's list. Toggle any tool below to customize."
    }

    private var mcpServersBannerTitle: String {
        if let allow = workspace.enabledMCPServers {
            if allow.isEmpty {
                return "No MCP-derived tools available"
            }
            return "\(allow.count) of \(vm.mcpServers.count) servers' tools available"
        }
        if vm.isDefaultWorkspace(workspace.id) {
            return "All MCP servers' tools available"
        }
        return "Inheriting from Default"
    }

    private var mcpServersBannerDetail: String {
        if let allow = workspace.enabledMCPServers {
            if allow.isEmpty {
                return "Every MCP server's tools are removed from this workspace's agent prompt. The servers themselves stay running — this is a per-workspace visibility filter, not a subprocess gate."
            }
            return "Tools from disallowed servers are removed from this workspace's agent prompt. Visibility filter only — the servers themselves keep running."
        }
        if vm.isDefaultWorkspace(workspace.id) {
            return "Default workspace inherits no further. Toggling any server below starts an explicit list."
        }
        return "Falling back to the Default workspace's list. Toggle any server below to customize."
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

/// Status banner used at the top of each Phase 4 allow-list tab in
/// the workspace settings sheet. Replaces the prior cryptic
/// `(N allowed)` disclosure-header chip with a sentence-form
/// description of the current effective state and a clear-override
/// action when applicable. Tinted background sets it apart from the
/// per-row toggle list below; the rounded panel idiom matches
/// macOS settings-sheet conventions.
private struct AllowListStatusBanner: View {
    let title: String
    let detail: String
    let isOverriding: Bool
    let onClearOverride: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isOverriding {
                Button {
                    onClearOverride()
                } label: {
                    Label("Use Default", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .controlSize(.small)
                .help("Clear this workspace's override; falls back to the Default workspace's list.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
