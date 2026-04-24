import SwiftUI
import AppKit

/// Minimal workspace management sheet. Dual-purpose:
///   - Edit mode: `vm.workspaceInSheet` set to an existing row,
///     `vm.creatingWorkspace` false. Name + folder editable; actions
///     are Rename, Set/Clear folder, Delete.
///   - Create mode: `vm.workspaceInSheet` nil, `vm.creatingWorkspace`
///     true. Name + folder fields empty; single action is Create.
///
/// Sheet-of-sheets (per-workspace detail + "all workspaces list")
/// would be better UX but adds complexity. The MVP shows one
/// workspace at a time; the list is reachable from the header menu.
struct WorkspaceSheet: View {
    let vm: ChatViewModel
    let dismiss: () -> Void

    @State private var name: String = ""
    @State private var dataFolder: String = ""
    @State private var confirmDelete: Bool = false
    @State private var didSeedFields: Bool = false

    private var isCreating: Bool { vm.creatingWorkspace }
    private var editingWorkspace: WorkspaceSummary? { vm.workspaceInSheet }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameField
                    dataFolderField
                    if let ws = editingWorkspace {
                        metadataSection(ws)
                    }
                    if !isCreating {
                        otherWorkspacesSection
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 480)
        .onAppear { seedFields() }
        .alert(
            "Delete workspace?",
            isPresented: $confirmDelete,
            actions: {
                Button("Delete", role: .destructive) {
                    if let id = editingWorkspace?.id {
                        vm.deleteWorkspace(id: id)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("Conversations assigned to this workspace will become unassigned (they stay in History). RAG sources for this workspace will need to be re-ingested into a new workspace.")
            }
        )
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(isCreating ? "New workspace" : (editingWorkspace?.name ?? "Workspace"))
                .font(.title3).fontWeight(.semibold)
            Spacer()
            Button("Close", action: dismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var nameField: some View {
        SectionLabel("Name")
        TextField("Workspace name", text: $name)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
    }

    @ViewBuilder
    private var dataFolderField: some View {
        SectionLabel("Data folder")
        HStack(spacing: 6) {
            TextField("No folder set", text: $dataFolder)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            Button {
                if let url = FileDialogs.openDirectory(
                    message: "Choose a folder whose files will be ingested into this workspace's RAG corpus"
                ) {
                    dataFolder = url.path
                }
            } label: {
                Image(systemName: "folder")
            }
            .controlSize(.small)
            .help("Choose folder")
            if !dataFolder.isEmpty {
                Button {
                    dataFolder = ""
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear folder")
            }
        }
        Text("Files in this folder become sources for retrieval-augmented generation (RAG) in conversations assigned to this workspace. Supported formats are `.txt`, `.md`, and `.json`. Scanning is on-demand — run it from this sheet after adding or changing files.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func metadataSection(_ ws: WorkspaceSummary) -> some View {
        SectionLabel("Stats")
        HStack(spacing: 14) {
            MetaLabel(key: "id", value: "\(ws.id)")
            MetaLabel(key: "conversations", value: "\(ws.conversationCount)")
            MetaLabel(key: "created", value: formatted(ws.createdAt))
        }
    }

    @ViewBuilder
    private var otherWorkspacesSection: some View {
        SectionLabel("All workspaces")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(vm.workspaces) { ws in
                Button {
                    vm.openWorkspaceDetails(ws)
                    didSeedFields = false
                    seedFields()
                } label: {
                    HStack {
                        if ws.id == editingWorkspace?.id {
                            Image(systemName: "circle.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Image(systemName: "circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(ws.name)
                            .font(.callout)
                        Spacer()
                        Text("\(ws.conversationCount) conv")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                ws.id == editingWorkspace?.id
                                    ? Color.accentColor.opacity(0.08)
                                    : Color.clear
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if !isCreating, let ws = editingWorkspace, ws.name != "Default" {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
            }
            Spacer()
            if isCreating {
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    vm.createWorkspace(
                        name: trimmed,
                        dataFolder: dataFolder.isEmpty ? nil : dataFolder
                    )
                    dismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if let ws = editingWorkspace {
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed != ws.name {
                        vm.renameWorkspace(id: ws.id, to: trimmed)
                    }
                    let folderValue = dataFolder.isEmpty ? nil : dataFolder
                    if folderValue != ws.dataFolder {
                        vm.setWorkspaceDataFolder(id: ws.id, dataFolder: folderValue)
                    }
                    dismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasPendingChanges(ws))
            }
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func seedFields() {
        guard !didSeedFields else { return }
        didSeedFields = true
        if let ws = editingWorkspace {
            name = ws.name
            dataFolder = ws.dataFolder ?? ""
        } else {
            name = ""
            dataFolder = ""
        }
    }

    private func hasPendingChanges(_ ws: WorkspaceSummary) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != ws.name { return true }
        let folderValue = dataFolder.isEmpty ? nil : dataFolder
        if folderValue != ws.dataFolder { return true }
        return false
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

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

private struct MetaLabel: View {
    let key: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
        .font(.caption2.monospaced())
    }
}
