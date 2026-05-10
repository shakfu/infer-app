import SwiftUI
import AppKit

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
    @State private var seededWorkspaceId: Int64 = -1
    @State private var confirmDelete: Bool = false
    @State private var confirmReset: Bool = false

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

    private func seedFields(force: Bool) {
        if force || seededWorkspaceId != workspace.id {
            name = workspace.name
            dataFolder = workspace.dataFolder ?? ""
            seededWorkspaceId = workspace.id
            vm.refreshCorpusStats(workspaceId: workspace.id)
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
