import SwiftUI

/// Header affordance showing the active workspace and offering a
/// one-click switch. Sits next to `AgentPickerMenu` so the two
/// cross-cutting concerns (which agent? which workspace?) live in
/// the same horizontal strip.
///
/// A workspace is a container for conversations + (optionally) a
/// folder of RAG sources. Every new conversation inherits the
/// currently-active workspace. Switching does not reassign the
/// current conversation.
struct WorkspacePickerMenu: View {
    let vm: ChatViewModel

    var body: some View {
        Menu {
            let workspaces = vm.workspaces
            if workspaces.isEmpty {
                Text("No workspaces")
            } else {
                Section {
                    ForEach(workspaces) { ws in
                        menuItem(for: ws)
                    }
                }
            }
            Divider()
            Button("New workspace…") {
                vm.openCreateWorkspaceSheet()
            }
            Button("Manage workspaces…") {
                vm.openWorkspaceManagement()
            }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tooltip)
    }

    @ViewBuilder
    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(activeName)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if vm.activeWorkspace?.dataFolder != nil {
                Image(systemName: "folder.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                    .help("This workspace has a data folder for RAG ingestion.")
            }
        }
    }

    @ViewBuilder
    private func menuItem(for ws: WorkspaceSummary) -> some View {
        let isActive = ws.id == vm.activeWorkspaceId
        Button {
            vm.switchWorkspace(to: ws.id)
        } label: {
            if isActive {
                Label(ws.name, systemImage: "checkmark")
            } else {
                Text(ws.name)
            }
        }
        .disabled(isActive)
    }

    private var activeName: String {
        vm.activeWorkspace?.name ?? "No workspace"
    }

    private var tooltip: String {
        guard let ws = vm.activeWorkspace else { return "No active workspace" }
        var t = "Workspace: \(ws.name)"
        if let folder = ws.dataFolder, !folder.isEmpty {
            t += " · folder: \(folder)"
        }
        return t
    }
}
