import Foundation
import InferAgents
import InferCore

extension ChatViewModel {
    /// Persist settings and apply them to whichever backend is currently loaded.
    /// Sampling params apply without a re-load; changing the system prompt
    /// resets the conversation (history is lost).
    ///
    /// When a non-Default agent is active, the agent — not
    /// `InferSettings` — is authoritative over the system prompt, so
    /// runner state is not re-pushed from here: this write only updates
    /// the Default-agent backing. The parameters panel is still live
    /// (the user can edit Default's parameters while a persona is
    /// active), but those edits don't take effect on the runner until
    /// the user switches back to Default.
    func applySettings(_ new: InferSettings) {
        let previous = settings
        settings = new
        new.save()
        persistPerWorkspaceParamChanges(new: new, previous: previous)

        // Llama load-time params (nCtx, nBatch) only take effect on the
        // next model load. Surface a toast rather than silently drop the
        // edit, so the user knows the slider isn't live. MLX/cloud
        // backends ignore these fields entirely.
        let loadParamsChanged = previous.nCtx != new.nCtx || previous.nBatch != new.nBatch
        if loadParamsChanged && backend == .llama && modelLoaded {
            toasts.show("Reload model to apply context/batch changes.")
        }

        let effects = agentController.applySettings(new, previous: previous)
        apply(effects)

        // Cloud runner is configured statelessly each turn but caches the
        // system prompt + sampling for re-send. Push fresh values when
        // the cloud backend is currently loaded; rebuilds history if the
        // system prompt changed (symmetric with MLX).
        if backend == .cloud, modelLoaded {
            let cloud = self.cloud
            let sp = new.systemPrompt
            let cloudParams = new.cloudParams()
            Task {
                await cloud.updateSettings(systemPrompt: sp, params: cloudParams)
            }
        }

        // Re-register the Quarto tool against the new override path so
        // the next render uses the right binary. Cheap (no process is
        // spawned at registration time) and safe to do unconditionally,
        // but we gate on a real change to avoid churning the registry
        // on every parameter slider tick.
        if previous.quartoPath != new.quartoPath {
            let registry = self.toolRegistry
            let path = new.quartoPath
            Task {
                await registry.unregister(name: "builtin.quarto.render")
                await registry.register(
                    QuartoRenderTool(locator: QuartoLocator(override: path))
                )
            }
        }

        // Same pattern for the web-search backend: when the SearXNG
        // endpoint changes (set, cleared, or edited), swap the
        // registered tool out so the next `web.search` call uses the
        // new backend. The tool's `Backend` enum is captured at init,
        // so re-construction is the cheapest correct path.
        if previous.searxngEndpoint != new.searxngEndpoint {
            let registry = self.toolRegistry
            let endpoint = new.searxngEndpoint
            Task {
                await registry.unregister(name: "web.search")
                await registry.register(WebSearchTool(searxngEndpoint: endpoint))
            }
        }

        // Tool output cap may have changed (global default or the
        // wikipedia.article-specific override). Re-register the
        // affected tool so the next call sees the new value. Same
        // re-construction pattern as web.search above.
        let prevWikiCap = previous.toolOutputCap(for: "wikipedia.article")
        let newWikiCap = new.toolOutputCap(for: "wikipedia.article")
        if prevWikiCap != newWikiCap {
            let registry = self.toolRegistry
            Task {
                await registry.unregister(name: "wikipedia.article")
                await registry.register(WikipediaArticleTool(maxBytes: newWikiCap))
            }
        }
    }

    /// Write the four per-workspace fields to the active workspace's
    /// row whenever they differ between `previous` (the prior composed
    /// effective settings) and `new` (the user's edit). Fields that
    /// did not change are left as `.unchanged` so a workspace's row
    /// stays NULL where it was inheriting from Default — preserving
    /// the live-inherit semantics promised in the design doc.
    /// No-op when no workspace is active (boot-time edge case before
    /// `refreshWorkspaces` finishes).
    private func persistPerWorkspaceParamChanges(new: InferSettings, previous: InferSettings) {
        guard let activeId = activeWorkspaceId else { return }
        let systemPromptWrite: VaultStore.ParamWrite<String?> =
            new.systemPrompt != previous.systemPrompt ? .value(new.systemPrompt) : .unchanged
        let temperatureWrite: VaultStore.ParamWrite<Double?> =
            new.temperature != previous.temperature ? .value(new.temperature) : .unchanged
        let topPWrite: VaultStore.ParamWrite<Double?> =
            new.topP != previous.topP ? .value(new.topP) : .unchanged
        let maxTokensWrite: VaultStore.ParamWrite<Int?> =
            new.maxTokens != previous.maxTokens ? .value(new.maxTokens) : .unchanged
        // Bail out early if every field is .unchanged — avoids an
        // empty-fragments DB write and a refresh round-trip.
        let anyChange = [
            paramWriteHasValue(systemPromptWrite),
            paramWriteHasValue(temperatureWrite),
            paramWriteHasValue(topPWrite),
            paramWriteHasValue(maxTokensWrite),
        ].contains(true)
        guard anyChange else { return }
        Task { [vault] in
            do {
                try await vault.setWorkspaceParams(
                    id: activeId,
                    systemPrompt: systemPromptWrite,
                    temperature: temperatureWrite,
                    topP: topPWrite,
                    maxTokens: maxTokensWrite
                )
                await MainActor.run { self.refreshWorkspaces() }
            } catch {
                self.logs.logFromBackground(
                    .error,
                    source: "workspaces",
                    message: "failed to persist per-workspace params",
                    payload: String(describing: error)
                )
            }
        }
    }

    private func paramWriteHasValue<T>(_ w: VaultStore.ParamWrite<T>) -> Bool {
        if case .value = w { return true }
        return false
    }

    /// Clear a single per-workspace param override on the active
    /// workspace. Wired up by the right-sidebar's per-field
    /// `[Use default]` button (Phase 1 task 4). After the clear, the
    /// effective settings recompose against Default's row and apply
    /// to the runner stack like any other settings change.
    func clearWorkspaceParamOverride(_ field: WorkspaceParamField) {
        guard let activeId = activeWorkspaceId else { return }
        Task { [vault] in
            do {
                switch field {
                case .systemPrompt:
                    try await vault.setWorkspaceParams(id: activeId, systemPrompt: .value(nil))
                case .temperature:
                    try await vault.setWorkspaceParams(id: activeId, temperature: .value(nil))
                case .topP:
                    try await vault.setWorkspaceParams(id: activeId, topP: .value(nil))
                case .maxTokens:
                    try await vault.setWorkspaceParams(id: activeId, maxTokens: .value(nil))
                }
                await MainActor.run {
                    self.refreshWorkspaces()
                    self.recomposeSettingsFromActiveWorkspace(applyToRunners: true)
                }
            } catch {
                self.logs.logFromBackground(
                    .error,
                    source: "workspaces",
                    message: "failed to clear workspace param override",
                    payload: String(describing: error)
                )
            }
        }
    }

    /// Identifies one of the four per-workspace param columns for
    /// `clearWorkspaceParamOverride`. Out-of-band from `InferSettings`
    /// because not every `InferSettings` field is per-workspace yet
    /// (Phase 1 covers four; Phases 2+ extend).
    enum WorkspaceParamField: Sendable {
        case systemPrompt
        case temperature
        case topP
        case maxTokens
    }

    /// True when the active workspace overrides the named field
    /// (i.e. its column is non-NULL). Drives the per-field
    /// `[Use default]` button's enable state in the sidebar.
    func activeWorkspaceOverrides(_ field: WorkspaceParamField) -> Bool {
        guard let active = activeWorkspace else { return false }
        switch field {
        case .systemPrompt: return active.systemPrompt != nil
        case .temperature:  return active.temperature != nil
        case .topP:         return active.topP != nil
        case .maxTokens:    return active.maxTokens != nil
        }
    }

    /// Recompute context-window usage for the active backend. llama reports
    /// real token counts; MLX has no cheap way to query, so approximate from
    /// transcript character count (~4 chars/token for English).
    ///
    /// Currently consumed only by code paths that may use the data later
    /// (vault, debug surfaces). The chat header no longer renders it —
    /// the progress bar was visually crowding the header. If/when a
    /// dedicated context-window UI lands, this is the data feed.
    func refreshTokenUsage() {
        let b = self.backend
        let msgs = self.messages
        let systemChars = self.settings.systemPrompt.count
        Task {
            let usage: TokenUsage?
            switch b {
            case .llama:
                usage = await self.llama.tokenUsage()
            case .mlx, .cloud:
                // Neither path exposes a cheap real token count. Approximate
                // from transcript char count (~4 chars/token for English) so
                // the consumer surfaces *something* — there's no reliable
                // total context size to report, so `total: nil` keeps the
                // header from rendering a misleading percentage.
                let chars = msgs.reduce(0) { $0 + $1.text.count } + systemChars
                usage = chars == 0 ? nil : TokenUsage(used: chars / 4, total: nil)
            }
            await MainActor.run { self.tokenUsage = usage }
        }
    }
}
