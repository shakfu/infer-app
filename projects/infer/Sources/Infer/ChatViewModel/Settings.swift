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

        let effects = agentController.applySettings(new, previous: previous)
        apply(effects)

        // Cloud runner is configured statelessly each turn but caches the
        // system prompt + sampling for re-send. Push fresh values when
        // the cloud backend is currently loaded; rebuilds history if the
        // system prompt changed (symmetric with MLX).
        if backend == .cloud, modelLoaded {
            let cloud = self.cloud
            let sp = new.systemPrompt
            let temp = new.temperature
            let p = new.topP
            Task {
                await cloud.updateSettings(systemPrompt: sp, temperature: temp, topP: p)
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
