import Foundation
import AppKit
import InferCore

extension ChatViewModel {
    /// Active workspace row (looked up from `workspaces` by id).
    /// Nil only transiently during app launch before the first
    /// `refreshWorkspaces` completes.
    var activeWorkspace: WorkspaceSummary? {
        guard let id = activeWorkspaceId else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// Load the workspace list from the vault, restore the persisted
    /// active-workspace selection, and log the result. Called once at
    /// VM init and after any CRUD mutation.
    func refreshWorkspaces() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await self.vault.listWorkspaces()
                await MainActor.run {
                    self.workspaces = list
                    self.restoreActiveWorkspaceSelection()
                }
            } catch {
                self.logs.logFromBackground(
                    .error,
                    source: "workspaces",
                    message: "listWorkspaces failed",
                    payload: String(describing: error)
                )
            }
        }
    }

    /// Install the saved active-workspace id (from UserDefaults), or
    /// fall back to the Default workspace. Called from the main actor
    /// after `workspaces` has been refreshed.
    @MainActor
    private func restoreActiveWorkspaceSelection() {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: PersistKey.activeWorkspaceId) as? Int64
            ?? (defaults.object(forKey: PersistKey.activeWorkspaceId) as? NSNumber)?.int64Value
        if let stored, workspaces.contains(where: { $0.id == stored }) {
            activeWorkspaceId = stored
            return
        }
        // Fall back to the Default workspace (pinned first by
        // listWorkspaces). If the list is empty — only possible on a
        // corrupted vault — leave nil; the header picker will show a
        // "no workspace" state.
        activeWorkspaceId = workspaces.first?.id
        if let id = activeWorkspaceId {
            defaults.set(NSNumber(value: id), forKey: PersistKey.activeWorkspaceId)
        }
    }

    /// Switch the active workspace. Persists the choice. New
    /// conversations after this point land in the new workspace; the
    /// current conversation (if any) is not reassigned.
    func switchWorkspace(to id: Int64) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        guard id != activeWorkspaceId else { return }
        activeWorkspaceId = id
        UserDefaults.standard.set(NSNumber(value: id), forKey: PersistKey.activeWorkspaceId)
        if let name = workspaces.first(where: { $0.id == id })?.name {
            logs.log(.info, source: "workspaces", message: "switched to \(name)")
        }
    }

    /// Create a new workspace and switch to it. Shown in the "New
    /// workspace…" flow from the management sheet.
    func createWorkspace(name: String, dataFolder: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await self.vault.createWorkspace(
                    name: name,
                    dataFolder: dataFolder
                )
                await MainActor.run {
                    self.refreshWorkspaces()
                    self.switchWorkspace(to: id)
                    self.toasts.show("Created workspace \"\(name)\".")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to create workspace: \(error)"
                }
            }
        }
    }

    /// Rename a workspace. UI surfaces from the management sheet.
    func renameWorkspace(id: Int64, to name: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.vault.renameWorkspace(id: id, name: name)
                await MainActor.run { self.refreshWorkspaces() }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to rename workspace: \(error)"
                }
            }
        }
    }

    /// Update a workspace's data folder (the path scanned for RAG
    /// ingestion). Pass nil to clear.
    func setWorkspaceDataFolder(id: Int64, dataFolder: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.vault.setWorkspaceDataFolder(
                    id: id, dataFolder: dataFolder
                )
                await MainActor.run { self.refreshWorkspaces() }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to set data folder: \(error)"
                }
            }
        }
    }

    /// Delete a workspace. Orphans its conversations (they stay in the
    /// vault with workspace_id = NULL, visible in the History tab).
    /// The caller is responsible for confirmation. Switches to the
    /// Default workspace if the deleted one was active.
    func deleteWorkspace(id: Int64) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.vault.deleteWorkspace(id: id)
                await MainActor.run {
                    self.refreshWorkspaces()
                    if self.activeWorkspaceId == id {
                        // refreshWorkspaces will restore selection to
                        // Default because the stored id no longer
                        // matches any row.
                        UserDefaults.standard.removeObject(
                            forKey: PersistKey.activeWorkspaceId
                        )
                    }
                    self.toasts.show("Workspace deleted.")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to delete workspace: \(error)"
                }
            }
        }
    }

    /// Present the workspace management sheet targeting the active
    /// workspace. If no active workspace exists, opens in create mode.
    @MainActor
    func openWorkspaceManagement() {
        if let active = activeWorkspace {
            workspaceInSheet = active
            creatingWorkspace = false
        } else {
            workspaceInSheet = nil
            creatingWorkspace = true
        }
    }

    @MainActor
    func openCreateWorkspaceSheet() {
        workspaceInSheet = nil
        creatingWorkspace = true
    }

    @MainActor
    func openWorkspaceDetails(_ workspace: WorkspaceSummary) {
        workspaceInSheet = workspace
        creatingWorkspace = false
    }
}
