import Foundation
import AppKit
import InferAgents
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
                    self.recomposeActiveAgentFromActiveWorkspace(insertDivider: false)
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
        recomposeActiveAgentFromActiveWorkspace(insertDivider: true)
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
            outputDirectory: row.outputDirectory,
            activeAgentId: row.activeAgentId,
            enabledAgents: row.enabledAgents,
            enabledTools: row.enabledTools,
            enabledMCPServers: row.enabledMCPServers
        )
    }

    /// Resolved set of agent ids the active workspace is willing to
    /// expose. `nil` return = "no allow-list active at any cascade
    /// layer" → every agent in the global registry is available.
    /// A non-nil return is the explicit allow-list (possibly empty),
    /// with `DefaultAgent.id` always merged in as a safety net so
    /// the user can never lock themselves out of a workspace.
    /// Phase 4a of the per-workspace-params feature; see
    /// `docs/dev/per-workspace-params.md` §12.3.
    var effectiveEnabledAgents: Set<AgentID>? {
        let resolved = WorkspaceParamCascade.resolve(
            active: activeWorkspace.map(Self.cascade(from:)),
            defaults: workspaces.min(by: { $0.id < $1.id }).map(Self.cascade(from:))
        )
        guard let raw = resolved.enabledAgents else { return nil }
        var set = Set(raw.map { AgentID(rawValue: $0) })
        // Safety net: DefaultAgent is always allowed regardless of
        // the persisted list. Enforced here (the consumer) rather
        // than in the cascade resolver so the cascade type stays
        // dependency-free (it doesn't know about `DefaultAgent`).
        set.insert(DefaultAgent.id)
        return set
    }

    /// True when the workspace allow-list explicitly excludes the
    /// given agent. `false` covers two cases: (a) no allow-list is
    /// active at any cascade layer (everything allowed); (b) the
    /// allow-list is active and includes this agent. Used by the
    /// agent picker to grey out / hide agents the user has
    /// silenced for this workspace.
    func isAgentEnabledInActiveWorkspace(_ id: AgentID) -> Bool {
        guard let allow = effectiveEnabledAgents else { return true }
        return allow.contains(id)
    }

    /// Combined visibility check: a listing is visible to the user
    /// when both (a) its declared backend / capabilities match the
    /// active runner (the existing `isCompatible` check) and (b)
    /// it isn't allow-listed away by the active workspace. Picker
    /// + sidebar callers replaced their bare `isCompatible` filter
    /// with this in Phase 4a so the workspace allow-list is
    /// honoured everywhere agents render. `DefaultAgent.id` always
    /// passes the allow-list half via the safety net in
    /// `effectiveEnabledAgents`.
    func isVisibleAgent(_ listing: AgentListing) -> Bool {
        isCompatible(listing) && isAgentEnabledInActiveWorkspace(listing.id)
    }

    /// Resolved set of tool names the active workspace permits.
    /// Composes Phase 4b (`enabled_tools` per-tool list) and Phase 4c
    /// (`enabled_mcp_servers` per-server list). `nil` return = "no
    /// allow-list active at either axis" → every tool the active
    /// agent declares is available. A non-nil return is the
    /// effective tool surface; the agent's declared tools are
    /// intersected with this inside `AgentController.activate`
    /// before being assigned to `activeToolSpecs`.
    ///
    /// Composition rule:
    ///   - Both nil → return nil (no filter).
    ///   - Phase 4b non-nil → start with that set.
    ///   - Phase 4b nil, Phase 4c non-nil → start with the universe
    ///     (`availableToolNames`).
    ///   - Phase 4c non-nil → subtract tool names of the form
    ///     `mcp.<disallowedServerID>.*` (every MCP-derived tool whose
    ///     owning server is NOT in the allow-list). MCP tool names
    ///     are constructed by `MCPBuiltinTool.init` as
    ///     `mcp.<serverID>.<rawToolName>`; the parse here mirrors that.
    ///
    /// **No safety net.** Unlike `effectiveEnabledAgents` (which
    /// always insists on `DefaultAgent.id`), an empty resolved set
    /// genuinely means "no tools available" — legitimate for
    /// security-sensitive workspaces.
    var effectiveEnabledTools: Set<String>? {
        let resolved = WorkspaceParamCascade.resolve(
            active: activeWorkspace.map(Self.cascade(from:)),
            defaults: workspaces.min(by: { $0.id < $1.id }).map(Self.cascade(from:))
        )
        let phase4b = resolved.enabledTools.map { Set($0) }
        let phase4c = resolved.enabledMCPServers.map { Set($0) }
        if phase4b == nil && phase4c == nil { return nil }
        // Build the starting set. If Phase 4b set the per-tool list,
        // use that; otherwise (Phase 4c is what's active) start with
        // the registry universe.
        var allowed: Set<String>
        if let phase4b {
            allowed = phase4b
        } else {
            allowed = Set(availableToolNames)
        }
        if let phase4c {
            // Subtract `mcp.<server>.*` for every server NOT in the
            // allow-list. Tools the registry knows about that don't
            // start with `mcp.` are unaffected.
            allowed = allowed.filter { name in
                guard name.hasPrefix("mcp.") else { return true }
                let stripped = String(name.dropFirst("mcp.".count))
                guard let dot = stripped.firstIndex(of: ".") else { return true }
                let serverID = String(stripped[..<dot])
                return phase4c.contains(serverID)
            }
        }
        return allowed
    }

    /// Resolved set of MCP server ids the active workspace permits.
    /// `nil` = no per-server allow-list active → every running
    /// server's tools are visible (subject to Phase 4b's per-tool
    /// filter). A non-nil set (possibly empty) is the explicit
    /// list; the consumer is `effectiveEnabledTools` above which
    /// subtracts tools of disallowed servers.
    var effectiveEnabledMCPServers: Set<String>? {
        let resolved = WorkspaceParamCascade.resolve(
            active: activeWorkspace.map(Self.cascade(from:)),
            defaults: workspaces.min(by: { $0.id < $1.id }).map(Self.cascade(from:))
        )
        guard let raw = resolved.enabledMCPServers else { return nil }
        return Set(raw)
    }

    /// True when the workspace allow-list permits the named MCP
    /// server. `false` only when an allow-list is active and excludes
    /// this server. Drives the per-row checkbox state in the
    /// workspace sheet's MCP servers disclosure.
    func isMCPServerEnabledInActiveWorkspace(_ serverID: String) -> Bool {
        guard let allow = effectiveEnabledMCPServers else { return true }
        return allow.contains(serverID)
    }

    /// Persist a new MCP server allow-list. Same semantics as
    /// `setWorkspaceEnabledTools`: nil clears, [] silences (no MCP
    /// tools), explicit list pins. After the write, refresh the
    /// workspace list and force-recompose tool specs so the running
    /// prompt picks up the new server-derived filter immediately.
    /// Shared "flip one id" logic behind the three `toggle…InAllowList`
    /// methods. When no allow-list exists yet (`current == nil`), the user
    /// is starting from the implicit "everything allowed" and removing one
    /// item, so materialise the explicit list as everything-except-target.
    /// Otherwise flip `target` in/out of the existing list.
    private func nextAllowList(current: [String]?, target: String, universe: [String]) -> [String] {
        guard let current else { return universe.filter { $0 != target } }
        return current.contains(target) ? current.filter { $0 != target } : current + [target]
    }

    /// Shared persistence path behind the three `setWorkspaceEnabled…`
    /// writers. `write` performs the one differing `vault.setWorkspaceParams`
    /// call; `postWrite` runs the axis-specific follow-up (tool-spec refresh
    /// or active-agent recompose) after the workspace list is refreshed.
    /// `label` names the axis in the failure log.
    private func persistAllowList(
        label: String,
        write: @escaping @Sendable () async throws -> Void,
        postWrite: @escaping @MainActor () -> Void
    ) {
        Task {
            do {
                try await write()
                await MainActor.run {
                    self.refreshWorkspaces()
                    postWrite()
                }
            } catch {
                self.logs.logFromBackground(
                    .error,
                    source: "workspaces",
                    message: "failed to persist \(label)",
                    payload: String(describing: error)
                )
            }
        }
    }

    func setWorkspaceEnabledMCPServers(id: Int64, ids: [String]?) {
        persistAllowList(
            label: "MCP servers allow-list",
            write: { [vault] in try await vault.setWorkspaceParams(id: id, enabledMCPServers: .value(ids)) },
            postWrite: { self.refreshActiveAgentToolSpecs() }
        )
    }

    /// Flip a single MCP server's membership in the named workspace's
    /// allow-list. Same first-toggle-materialises-everything-except-
    /// this idiom as the agents and tools allow-lists. The "universe"
    /// is the current set of `mcpServers` summaries — runtime-
    /// discovered, so a server that wasn't running when the user
    /// opened the sheet won't appear; refresh on sheet-open.
    func toggleMCPServerInAllowList(workspaceId: Int64, serverID: String, universe: [String]) {
        guard let row = workspaces.first(where: { $0.id == workspaceId }) else { return }
        let next = nextAllowList(current: row.enabledMCPServers, target: serverID, universe: universe)
        setWorkspaceEnabledMCPServers(id: workspaceId, ids: next)
    }

    /// True when the workspace allow-list permits the named tool.
    /// `false` only when an allow-list is active and excludes this
    /// tool. Drives the per-row checkbox state in the workspace
    /// sheet's tools disclosure.
    func isToolEnabledInActiveWorkspace(_ toolName: String) -> Bool {
        guard let allow = effectiveEnabledTools else { return true }
        return allow.contains(toolName)
    }

    /// Persist a new tool allow-list for the named workspace.
    /// Same semantics as `setWorkspaceEnabledAgents`: `nil` clears
    /// the override, `[]` is the workspace-silenced state, an
    /// explicit list pins. After the write, refreshes the workspace
    /// list and **force-refreshes the active agent's tool specs**
    /// (`refreshActiveAgentToolSpecs`) so the change takes effect on
    /// the next turn without requiring an agent switch.
    func setWorkspaceEnabledTools(id: Int64, ids: [String]?) {
        persistAllowList(
            label: "tools allow-list",
            write: { [vault] in try await vault.setWorkspaceParams(id: id, enabledTools: .value(ids)) },
            postWrite: { self.refreshActiveAgentToolSpecs() }
        )
    }

    /// Refresh `availableToolNames` from the registry. Async because
    /// `toolRegistry.allSpecs()` hops the actor; the result is
    /// committed back on the main actor for SwiftUI observation.
    /// Called from the workspace sheet's onAppear so the per-row
    /// checkbox list reflects the latest tool catalogue (MCP tools
    /// can register / unregister at runtime, so a snapshot at
    /// VM-init time would go stale).
    func refreshAvailableToolNames() {
        Task { [weak self, registry = self.toolRegistry] in
            let names = await registry.allSpecs().map(\.name).sorted()
            await MainActor.run { self?.availableToolNames = names }
        }
    }

    /// Force-recompute the active agent's `activeToolSpecs` against
    /// the current workspace allow-list, without changing the
    /// active agent. Called after `setWorkspaceEnabledTools` so the
    /// running prompt picks up the new filter immediately rather
    /// than waiting for the next agent switch. Routes through the
    /// `AgentController.activateForSegment(...forceRefresh: true)`
    /// path that bypasses the same-id no-op guard.
    @MainActor
    func refreshActiveAgentToolSpecs() {
        let currentAgent = agentController.activeAgentId
        let backend = currentBackendPreference
        let settings = self.settings
        let enabled = effectiveEnabledTools
        Task { [controller = self.agentController] in
            let effects = await controller.activateForSegment(
                agentId: currentAgent,
                currentBackend: backend,
                settings: settings,
                enabledTools: enabled,
                forceRefresh: true
            )
            await MainActor.run { self.apply(effects) }
        }
    }

    /// Flip a single tool's membership in the named workspace's
    /// allow-list. Same first-toggle-materialises-everything-except-
    /// this semantics as `toggleAgentInAllowList`. The "universe" of
    /// tools is whatever the registry currently knows (may include
    /// MCP-derived tools — those are runtime-discovered, so the
    /// universe is dynamic).
    func toggleToolInAllowList(workspaceId: Int64, toolName: String, universe: [String]) {
        guard let row = workspaces.first(where: { $0.id == workspaceId }) else { return }
        let next = nextAllowList(current: row.enabledTools, target: toolName, universe: universe)
        setWorkspaceEnabledTools(id: workspaceId, ids: next)
    }

    /// Flip a single agent's membership in the named workspace's
    /// allow-list. If no allow-list is currently set, the toggle
    /// materialises one — populated with every currently-available
    /// agent except the one being toggled (so flipping a single
    /// switch produces "everything except this one" rather than
    /// "only this one"). This matches the intent of "I'm editing
    /// the list and want to remove this." Subsequent toggles flip
    /// individual ids in/out.
    func toggleAgentInAllowList(workspaceId: Int64, agentId: AgentID) {
        guard let row = workspaces.first(where: { $0.id == workspaceId }) else { return }
        let universe = availableAgents.map(\.id.rawValue)
        let next = nextAllowList(current: row.enabledAgents, target: agentId.rawValue, universe: universe)
        setWorkspaceEnabledAgents(id: workspaceId, ids: next)
    }

    /// Persist a new allow-list for the named workspace. `nil`
    /// clears the override (workspace falls back to Default's
    /// list, which itself may be `nil` = everything). An explicit
    /// `[]` is the workspace-silenced state; `DefaultAgent` is
    /// still available via the read-time safety net. After the
    /// write, refreshes the workspace list and re-runs the Phase 3
    /// active-agent recompose so a now-disallowed active agent
    /// gracefully degrades to Default.
    func setWorkspaceEnabledAgents(id: Int64, ids: [String]?) {
        persistAllowList(
            label: "agents allow-list",
            write: { [vault] in try await vault.setWorkspaceParams(id: id, enabledAgents: .value(ids)) },
            // Re-run the Phase 3 recompose so an active agent that just got
            // allow-listed-out degrades to Default. `insertDivider: true`
            // because this is a user-driven mid-session change — same shape
            // as a workspace switch.
            postWrite: { self.recomposeActiveAgentFromActiveWorkspace(insertDivider: true) }
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

    /// Resolve the effective active-agent id from the workspace
    /// cascade and align `agentController.activeAgentId` with it.
    /// Called from boot (`insertDivider: false`, runs through the
    /// silent `activateForSegment` path which produces only
    /// runner-state effects) and from workspace switch
    /// (`insertDivider: true`, runs through the full `switchAgent`
    /// path which prepends a transcript divider and invalidates the
    /// vault conversation row, same as a manual agent switch).
    ///
    /// **Graceful degradation.** If the resolved agent id isn't
    /// listed in `availableAgents` (registry evicted it, or it
    /// requires a backend the active runner doesn't speak), fall
    /// back to `DefaultAgent.id`. Three reasons this can fire:
    /// (1) the saved agent id was a persona the user later deleted;
    /// (2) the workspace's saved agent is incompatible with the
    /// currently-active backend (e.g. a vision-only agent saved
    /// while llama is loaded); (3) Phase 4's tool allow-list
    /// later disables the tools the saved agent depends on. The
    /// caller's UI still works because `DefaultAgent` is always
    /// compatible.
    @MainActor
    func recomposeActiveAgentFromActiveWorkspace(insertDivider: Bool) {
        let resolved = WorkspaceParamCascade.resolve(
            active: activeWorkspace.map(Self.cascade(from:)),
            defaults: workspaces.min(by: { $0.id < $1.id }).map(Self.cascade(from:))
        )
        // No persisted preference at either layer → leave the
        // controller at whatever it was. Boot leaves it at
        // `DefaultAgent.id`; subsequent calls leave the running
        // agent untouched.
        guard let rawId = resolved.activeAgentId, !rawId.isEmpty else { return }
        let target = AgentID(rawValue: rawId)
        guard target != agentController.activeAgentId else { return }
        // Find the listing and check compatibility; fall back to
        // Default if the saved id is no longer reachable.
        let backend = currentBackendPreference
        let candidate = availableAgents.first { $0.id == target }
        let listing: AgentListing
        if let candidate,
           agentController.isCompatible(candidate, backend: backend),
           isAgentEnabledInActiveWorkspace(candidate.id)
        {
            listing = candidate
        } else {
            // Saved id is unreachable — unknown / evicted / incompatible.
            // Fall back to Default; that listing is always present
            // (it's the synthetic Default entry the controller
            // always exposes) and always compatible.
            guard let fallback = availableAgents.first(where: { $0.id == DefaultAgent.id }) else {
                return
            }
            // If we already have Default active, no-op.
            guard fallback.id != agentController.activeAgentId else { return }
            listing = fallback
            logs.log(
                .warning,
                source: "agents",
                message: "workspace's saved agent '\(rawId)' is unreachable for backend \(backend); falling back to Default"
            )
        }
        let settingsSnapshot = self.settings
        let enabledToolsSnapshot = self.effectiveEnabledTools
        let mode: AgentRecomposeMode = insertDivider ? .switchAgent : .activateForSegment
        Task { [controller = self.agentController] in
            let effects: [AgentEffect]
            switch mode {
            case .switchAgent:
                effects = await controller.switchAgent(
                    to: listing,
                    currentBackend: backend,
                    settings: settingsSnapshot,
                    enabledTools: enabledToolsSnapshot
                )
            case .activateForSegment:
                effects = await controller.activateForSegment(
                    agentId: listing.id,
                    currentBackend: backend,
                    settings: settingsSnapshot,
                    enabledTools: enabledToolsSnapshot
                )
            }
            await MainActor.run { self.apply(effects) }
        }
    }

    /// Indirection for `recomposeActiveAgentFromActiveWorkspace` so the
    /// boot-vs-switch dispatch is at the call site rather than buried
    /// in a string flag. Boot wants the silent activation path
    /// (`activateForSegment`); workspace switch wants the full path
    /// (`switchAgent`) including the transcript divider.
    private enum AgentRecomposeMode {
        case switchAgent
        case activateForSegment
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
