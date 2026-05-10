import Foundation
import AppKit
import InferAppCore
import InferCore
import InferRAG

extension ChatViewModel {
    // MARK: - Per-workspace settings (UserDefaults-backed)

    /// Read a per-workspace boolean setting. Pure convenience over
    /// `UserDefaults.standard.bool(forKey:)` with a consistent key
    /// shape (`infer.workspace.<id>.<setting>`) so settings storage
    /// stays greppable and mistake-resistant.
    func workspaceSetting(
        _ setting: PersistKey.WorkspaceSetting,
        workspaceId: Int64,
        default defaultValue: Bool = false
    ) -> Bool {
        let key = PersistKey.workspaceKey(id: workspaceId, setting: setting.rawValue)
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultValue
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Write a per-workspace boolean setting.
    func setWorkspaceSetting(
        _ setting: PersistKey.WorkspaceSetting,
        workspaceId: Int64,
        _ value: Bool
    ) {
        let key = PersistKey.workspaceKey(id: workspaceId, setting: setting.rawValue)
        UserDefaults.standard.set(value, forKey: key)
    }

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
    ///
    /// On the first v5 launch this also migrates the legacy
    /// `UserDefaults` global params (`infer.systemPrompt` /
    /// `.temperature` / `.topP` / `.maxTokens`) into the Default
    /// workspace's row — the row is the new global floor (see
    /// `docs/dev/per-workspace-params.md`). Idempotent: subsequent
    /// launches see Default's columns already populated and skip the
    /// migration step. After the list reflects post-migration state,
    /// `recomposeSettingsFromActiveWorkspace()` rebuilds the
    /// effective settings the runners will see.
    func refreshWorkspaces() {
        Task { [weak self] in
            guard let self else { return }
            do {
                var list = try await self.vault.listWorkspaces()
                if let defaultRow = list.first(where: { Self.isDefaultRow($0, in: list) }),
                   defaultRow.systemPrompt == nil,
                   defaultRow.temperature == nil,
                   defaultRow.topP == nil,
                   defaultRow.maxTokens == nil
                {
                    await self.migrateLegacyGlobalsIntoDefault(defaultId: defaultRow.id)
                    // Re-fetch so the in-memory list reflects the
                    // freshly-populated Default row before settings
                    // composition reads from it.
                    list = try await self.vault.listWorkspaces()
                }
                await MainActor.run {
                    self.workspaces = list
                    self.restoreActiveWorkspaceSelection()
                    self.recomposeSettingsFromActiveWorkspace(applyToRunners: false)
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

    /// Vault-side migration of legacy `UserDefaults` globals into the
    /// Default workspace's row. One-shot: caller gates on Default's
    /// columns being all-NULL, so re-running this method on a
    /// post-migration vault is a no-op (no DB write because every
    /// `setWorkspaceParams` field would be `.value(<existing>)` which
    /// the writer happily UPSERTs but is benign).
    private func migrateLegacyGlobalsIntoDefault(defaultId: Int64) async {
        let d = UserDefaults.standard
        let legacySystemPrompt = d.string(forKey: PersistKey.systemPrompt) ?? ""
        let legacyTemperature = d.object(forKey: PersistKey.temperature) as? Double
            ?? InferSettings.defaults.temperature
        let legacyTopP = d.object(forKey: PersistKey.topP) as? Double
            ?? InferSettings.defaults.topP
        let legacyMaxTokens = d.object(forKey: PersistKey.maxTokens) as? Int
            ?? InferSettings.defaults.maxTokens
        do {
            try await vault.setWorkspaceParams(
                id: defaultId,
                systemPrompt: .value(legacySystemPrompt),
                temperature: .value(legacyTemperature),
                topP: .value(legacyTopP),
                maxTokens: .value(legacyMaxTokens)
            )
            logs.logFromBackground(
                .info,
                source: "workspaces",
                message: "v5: migrated legacy global params into Default workspace"
            )
        } catch {
            logs.logFromBackground(
                .error,
                source: "workspaces",
                message: "v5 legacy params migration failed",
                payload: String(describing: error)
            )
        }
    }

    /// Default-row identifier (the lowest id in the list — `listWorkspaces`
    /// pins it first, but resolving by id rather than by sort order keeps
    /// this honest if listing semantics change).
    private static func isDefaultRow(_ candidate: WorkspaceSummary, in list: [WorkspaceSummary]) -> Bool {
        guard let lowest = list.map(\.id).min() else { return false }
        return candidate.id == lowest
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
    ///
    /// Recomposes the effective `InferSettings` (per-workspace fields
    /// overlaid on Default's row) and applies them to the runner stack
    /// — the same path a slider drag takes — so the next turn runs
    /// against the new workspace's params.
    func switchWorkspace(to id: Int64) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        guard id != activeWorkspaceId else { return }
        activeWorkspaceId = id
        UserDefaults.standard.set(NSNumber(value: id), forKey: PersistKey.activeWorkspaceId)
        if let name = workspaces.first(where: { $0.id == id })?.name {
            logs.log(.info, source: "workspaces", message: "switched to \(name)")
        }
        recomposeSettingsFromActiveWorkspace(applyToRunners: true)
    }

    /// Resolve the four per-workspace fields (`systemPrompt`,
    /// `temperature`, `topP`, `maxTokens`) using the active workspace
    /// → Default workspace → legacy `UserDefaults` fallback chain.
    /// All other `InferSettings` fields stay sourced from
    /// `UserDefaults` (Phase 1 scope; Phase 2+ extends).
    ///
    /// The two-layer cascade itself lives in
    /// `InferAppCore.WorkspaceParamCascade.resolve` so it is unit-
    /// testable without `@testable`-importing this executable target;
    /// this method is the chat-VM wrapper that turns
    /// `WorkspaceSummary` rows into cascade values and lays the
    /// result over an `InferSettings` populated from `UserDefaults`.
    func composeEffectiveSettings() -> InferSettings {
        var s = InferSettings.load()
        let resolved = WorkspaceParamCascade.resolve(
            active: activeWorkspace.map(Self.cascade(from:)),
            defaults: workspaces.min(by: { $0.id < $1.id }).map(Self.cascade(from:))
        )
        if let v = resolved.systemPrompt { s.systemPrompt = v }
        if let v = resolved.temperature { s.temperature = v }
        if let v = resolved.topP { s.topP = v }
        if let v = resolved.maxTokens { s.maxTokens = v }
        return s
    }

    /// Adapter from the SQL-shaped `WorkspaceSummary` to the
    /// `InferAppCore` value type the cascade resolver consumes.
    static func cascade(from row: WorkspaceSummary) -> WorkspaceParamCascade {
        WorkspaceParamCascade(
            systemPrompt: row.systemPrompt,
            temperature: row.temperature,
            topP: row.topP,
            maxTokens: row.maxTokens,
            outputDirectory: row.outputDirectory
        )
    }

    /// Effective output directory for the active workspace, as a
    /// `URL`. Two-layer cascade plus a hardcoded final fallback —
    /// active workspace's `output_directory` wins, falling through to
    /// Default's column, falling through to the legacy
    /// `Application Support/Infer/Generated Images/` path. Tilde
    /// expansion is applied so a stored `~/Pictures/Infer/` resolves
    /// against the current `$HOME`.
    var effectiveOutputDirectory: URL {
        let resolved = WorkspaceParamCascade.resolve(
            active: activeWorkspace.map(Self.cascade(from:)),
            defaults: workspaces.min(by: { $0.id < $1.id }).map(Self.cascade(from:))
        )
        if let raw = resolved.outputDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return Self.legacyOutputDirectory()
    }

    /// Hardcoded fallback used when neither the active workspace nor
    /// Default has an `output_directory` set. Mirrors the original
    /// `sdOutputDirectory` location so existing users see no change
    /// on the v6 migration.
    static func legacyOutputDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("Infer", isDirectory: true)
            .appendingPathComponent("Generated Images", isDirectory: true)
    }

    /// Persist a workspace's `output_directory` override. Pass `nil`
    /// to clear (falls back to Default's row, then to the legacy
    /// path). Trimmed to nil-on-empty so a user-cleared field doesn't
    /// store the empty string.
    func setWorkspaceOutputDirectory(id: Int64, path: String?) {
        let normalized: String? = path
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        Task { [vault] in
            do {
                try await vault.setWorkspaceParams(id: id, outputDirectory: .value(normalized))
                await MainActor.run { self.refreshWorkspaces() }
            } catch {
                self.logs.logFromBackground(
                    .error,
                    source: "workspaces",
                    message: "failed to set workspace output directory",
                    payload: String(describing: error)
                )
            }
        }
    }

    /// Pull the effective settings into `self.settings`. `applyToRunners`
    /// gates whether the change propagates through the existing
    /// `applySettings` runner-update pipeline — true for user-driven
    /// transitions (workspace switch, edit), false for the initial
    /// boot-time composition where no runner is loaded yet.
    @MainActor
    func recomposeSettingsFromActiveWorkspace(applyToRunners: Bool) {
        let effective = composeEffectiveSettings()
        if applyToRunners {
            applySettings(effective)
        } else {
            settings = effective
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
    /// Also drops the workspace's RAG corpus from the vector store —
    /// sources + chunks + vec_items — since that data is derived and
    /// specific to this workspace. The caller is responsible for
    /// confirmation.
    /// True if the given workspace is the system-created Default —
    /// the v4 schema backfill creates it as the lowest-id row, and
    /// every subsequent workspace gets a higher id from the
    /// AUTOINCREMENT sequence. The Default is protected against
    /// deletion + rename so the app always has a fallback workspace
    /// for unassigned conversations to land in.
    func isDefaultWorkspace(_ id: Int64) -> Bool {
        guard let lowest = workspaces.map(\.id).min() else { return false }
        return id == lowest
    }

    /// Clear a workspace's per-workspace inference-parameter overrides.
    /// Leaves wiki pages, RAG corpus, conversations, name, and
    /// `data_folder` intact — this is a *narrow* reset, not a content
    /// wipe.
    ///
    /// For the Default workspace: clears the row's four columns to
    /// NULL, which restores the hard-coded `InferSettings.defaults`
    /// floor (since Default IS the globals layer and there is no
    /// further fallback). For a non-Default workspace: clears the
    /// sparse overrides so the workspace falls back to inheriting
    /// from Default. The four per-field `↺ Default` buttons in the
    /// sidebar already cover the per-field version of this; this is
    /// the bulk variant.
    ///
    /// Re-fetches the workspace list and recomposes effective
    /// settings so the runner stack picks up the cleared values on
    /// the next turn.
    func resetWorkspace(id: Int64) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.vault.setWorkspaceParams(
                    id: id,
                    systemPrompt: .value(nil),
                    temperature: .value(nil),
                    topP: .value(nil),
                    maxTokens: .value(nil)
                )
                await MainActor.run {
                    self.refreshWorkspaces()
                    self.recomposeSettingsFromActiveWorkspace(applyToRunners: true)
                    self.toasts.show("Parameters reset to defaults.")
                }
            } catch {
                self.logs.logFromBackground(
                    .error,
                    source: "workspaces",
                    message: "reset: failed to clear param overrides",
                    payload: String(describing: error)
                )
            }
        }
    }

    func deleteWorkspace(id: Int64) {
        // Refuse to delete the Default workspace; the caller (UI)
        // shouldn't be offering this option but we guard at the VM
        // layer too in case of a stale view or programmatic call.
        if isDefaultWorkspace(id) {
            toasts.show("The Default workspace can't be deleted. Use Reset to clear its data.")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.vault.deleteWorkspace(id: id)
                // Drop the workspace's vector data too; failures here
                // are non-fatal (the corpus is derived, re-ingestable).
                do {
                    try await self.vectorStore.deleteWorkspaceData(
                        workspaceId: id
                    )
                } catch {
                    self.logs.logFromBackground(
                        .warning,
                        source: "vector",
                        message: "failed to delete workspace vector data",
                        payload: String(describing: error)
                    )
                }
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
