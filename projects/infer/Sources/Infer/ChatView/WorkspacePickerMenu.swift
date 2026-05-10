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
    /// Fired when the user picks "Manage current workspace…". The
    /// sidebar owns the sheet presentation state; the picker just
    /// signals the request. Optional so callers that don't surface a
    /// settings sheet (currently none, but kept additive) can omit
    /// the entry.
    var onManageWorkspace: (() -> Void)? = nil

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
            // Discoverability path for the workspace settings sheet
            // alongside the dedicated cog at the sidebar's bottom-
            // left. Both paths land on the same modal panel; macOS
            // apps routinely offer multiple paths to the same
            // action and users naturally explore in different
            // places. Disabled when no workspace is active (boot
            // edge case before `refreshWorkspaces` finishes).
            if let onManageWorkspace {
                Button("Manage current workspace…") {
                    onManageWorkspace()
                }
                .disabled(vm.activeWorkspaceId == nil)
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
            // Phase 5d: subtle indicator when the active workspace
            // overrides any cascade axis. Small accent-tinted dot
            // reading "this workspace is customised" — tooltips
            // detail which axes. Only renders for non-Default
            // workspaces with at least one override; Default IS the
            // floor so the concept of "overriding" doesn't apply.
            if showsOverrideIndicator {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Color.accentColor)
                    .help(overrideIndicatorTooltip)
            }
        }
    }

    /// True only when the active workspace is non-Default AND has
    /// at least one cascade-axis override. Read directly from the
    /// active row's columns rather than the cascade resolver
    /// because the resolver hides which workspace contributed the
    /// override.
    private var showsOverrideIndicator: Bool {
        guard let ws = vm.activeWorkspace else { return false }
        guard !vm.isDefaultWorkspace(ws.id) else { return false }
        return ws.systemPrompt != nil
            || ws.temperature != nil
            || ws.topP != nil
            || ws.maxTokens != nil
            || ws.outputDirectory != nil
            || ws.activeAgentId != nil
            || ws.enabledAgents != nil
            || ws.enabledTools != nil
            || ws.enabledMCPServers != nil
    }

    /// Enumerate which axes are overridden in the tooltip so the
    /// user can tell at a glance which parts of the workspace
    /// diverge from Default without opening the settings panel.
    private var overrideIndicatorTooltip: String {
        guard let ws = vm.activeWorkspace else { return "" }
        var axes: [String] = []
        if ws.systemPrompt != nil { axes.append("system prompt") }
        if ws.temperature != nil { axes.append("temperature") }
        if ws.topP != nil { axes.append("top-p") }
        if ws.maxTokens != nil { axes.append("max tokens") }
        if ws.outputDirectory != nil { axes.append("output directory") }
        if ws.activeAgentId != nil { axes.append("active agent") }
        if ws.enabledAgents != nil { axes.append("agents allow-list") }
        if ws.enabledTools != nil { axes.append("tools allow-list") }
        if ws.enabledMCPServers != nil { axes.append("MCP servers allow-list") }
        guard !axes.isEmpty else { return "" }
        return "This workspace overrides Default on: \(axes.joined(separator: ", "))."
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
