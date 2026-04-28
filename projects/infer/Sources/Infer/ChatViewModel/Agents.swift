import Foundation
import AppKit
import InferAgents
import InferCore
import PluginAPI

extension ChatViewModel {
    /// Root directory under which user-authored JSON personas/agents live.
    /// `~/Library/Application Support/Infer/`. Subdirectories `personas/`
    /// and `agents/` are scanned individually; both are optional.
    static func userAgentsRootDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Infer", isDirectory: true)
    }

    /// `~/Library/Application Support/Infer/personas/`.
    static func userPersonasDirectory() -> URL {
        userAgentsRootDirectory()
            .appendingPathComponent("personas", isDirectory: true)
    }

    /// `~/Library/Application Support/Infer/agents/`.
    static func userAgentsDirectory() -> URL {
        userAgentsRootDirectory()
            .appendingPathComponent("agents", isDirectory: true)
    }

    /// `~/Library/Application Support/Infer/mcp/`. Holds one
    /// `MCPServerConfig` JSON per server. Missing directory is fine
    /// (no servers configured); per-file errors surface as Console
    /// diagnostics.
    static func userMCPDirectory() -> URL {
        userAgentsRootDirectory()
            .appendingPathComponent("mcp", isDirectory: true)
    }

    // MARK: - Controller passthrough

    var availableAgents: [AgentListing] { agentController.availableAgents }
    var activeAgentId: AgentID { agentController.activeAgentId }
    var activeDecodingParams: DecodingParams { agentController.activeDecodingParams }
    var libraryDiagnostics: [AgentRegistry.PersonaLoadError] {
        agentController.libraryDiagnostics
    }
    /// Number of tools exposed to the active agent for the current turn.
    /// Read by the header picker's `tools: N` chip so the user knows
    /// whether the agent can call tools without opening its JSON.
    var activeToolCount: Int { agentController.activeToolSpecs.count }

    /// Active agent's listing, if any (never nil in practice: the Default
    /// synthetic row is always present once bootstrap completes).
    var activeAgentListing: AgentListing? {
        availableAgents.first { $0.id == activeAgentId }
    }

    func isCompatible(_ listing: AgentListing) -> Bool {
        agentController.isCompatible(listing, backend: currentBackendPreference)
    }

    func incompatibilityReason(_ listing: AgentListing) -> String {
        agentController.incompatibilityReason(listing, backend: currentBackendPreference)
    }

    func activeAgentName() -> String { agentController.activeAgentName() }

    // MARK: - Lifecycle

    /// Resolve URLs of bundled first-party personas and agents. Looks
    /// inside `Bundle.module` (the SwiftPM-generated resource bundle for
    /// this target) under both `personas/` and `agents/` subdirectories —
    /// same paths used by `.copy("Resources/personas")` and
    /// `.copy("Resources/agents")` in `Package.swift`.
    ///
    /// Order is stable but not meaningful; `kind` in each JSON drives
    /// classification, the directory is only a hint (per
    /// `docs/dev/agent_kinds.md`).
    static func firstPartyPersonaURLs() -> [URL] {
        let personas = Bundle.module.urls(
            forResourcesWithExtension: "json",
            subdirectory: "personas"
        ) ?? []
        let agents = Bundle.module.urls(
            forResourcesWithExtension: "json",
            subdirectory: "agents"
        ) ?? []
        return personas + agents
    }

    /// Called from `ChatViewModel.init`. Seeds cached decoding params
    /// synchronously then kicks off async persona discovery, tool
    /// registration, and catalog publication to the controller.
    /// Log the RAG vector store's row counts once at startup so
    /// we can confirm the FTS5 index matches the `chunks` table.
    /// Mismatch = backfill didn't cover existing chunks and hybrid
    /// retrieval is operating on a partial index.
    func logRAGIndexHealth() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let (chunks, fts) = try await self.vectorStore.rowCounts()
                let level: LogLevel = (chunks == fts) ? .info : .warning
                self.logs.logFromBackground(
                    level,
                    source: "rag",
                    message: "index health: chunks=\(chunks), chunks_fts=\(fts)\(chunks == fts ? "" : " (MISMATCH)")"
                )
            } catch {
                self.logs.logFromBackground(
                    .warning,
                    source: "rag",
                    message: "index health check failed",
                    payload: String(describing: error)
                )
            }
        }
    }

    /// Build the agent-layer retrieval closure that wraps the host's
    /// vector store + embedder. Captures `weak self` so a teardown
    /// during a long retrieval doesn't keep the VM alive. Returns nil-
    /// equivalent (an empty array) when no workspace is active or the
    /// active workspace has no corpus — agents then degrade to
    /// parametric knowledge instead of erroring.
    func makeAgentRetriever() -> Retriever {
        return { [weak self] query, topK in
            guard let self else { return [] }
            // Hop to MainActor to read the live workspace id, then drop
            // back off-actor for the corpus check + embedding + search,
            // none of which need MainActor isolation. `vectorStore` and
            // `embedder` are actors / Sendable.
            let workspaceId: Int64? = await MainActor.run { self.activeWorkspaceId }
            guard let workspaceId else { return [] }
            let hasCorpus = await self.workspaceHasCorpus(workspaceId)
            guard hasCorpus else { return [] }
            try await self.ensureEmbeddingModelLoaded()
            let queryVec = try await self.embedder.embed(query)
            let hits = try await self.vectorStore.search(
                workspaceId: workspaceId,
                queryEmbedding: queryVec,
                queryText: query,
                k: topK
            )
            // Map sqlite-vec's distance into a relevance score in
            // roughly [0, 1]. Cosine distance lands in [0, 2]; the
            // `1 - d/2` mapping keeps the agent-facing score
            // monotone-increasing-with-relevance regardless of the
            // host's distance metric. Fused / FTS-only hits already
            // ride the vector hit's distance through `rrfFuse`.
            return hits.map { hit in
                RetrievedChunk(
                    sourceURI: hit.sourceURI,
                    content: hit.content,
                    score: max(0.0, 1.0 - hit.distance / 2.0)
                )
            }
        }
    }

    func bootstrapAgents() {
        let firstParty = Self.firstPartyPersonaURLs()
        let retriever = self.makeAgentRetriever()
        Task { [weak self, controller = self.agentController, registry = self.toolRegistry, settings = self.settings, logs = self.logs, mcpHost = self.mcpHost, retriever] in
            // Register the PR 2 built-ins. Tool registrations and the
            // controller bootstrap happen in the same task so the
            // first switchAgent after launch sees a populated catalog.
            await registry.register([
                ClockNowTool(),
                WordCountTool(),
                // Quarto render tool. Locator picks up the user's
                // `quartoPath` override from settings; nil falls back
                // to PATH and common install locations. Re-registered
                // on settings change via `reregisterQuartoTool`.
                QuartoRenderTool(
                    locator: QuartoLocator(override: settings.quartoPath)
                ),
                // Synthetic dispatch primitive for orchestrator agents
                // (M5c). The router emits a tool call; the
                // composition driver reads it from the trace
                // post-segment and dispatches to the chosen candidate.
                AgentsInvokeTool(),
                // Structured handoff dispatch (replaces the free-text
                // `<<HANDOFF>>` envelope). The composition driver reads
                // the call from the trace and follows the handoff;
                // the envelope parser stays as a fallback for older
                // configs.
                AgentsHandoffTool(),
                // Real tools. The fs.read sandbox is restricted to the
                // user's Documents directory + the Infer Application
                // Support root so agents can read user-authored notes
                // and persona JSON without exposing arbitrary disk.
                // The http.fetch allowlist is intentionally narrow and
                // points at canonical sources of structured public
                // content (Wikipedia HTML/JSON, raw GitHub files); it
                // can be extended by users authoring custom agents
                // once a settings surface lands.
                FilesystemReadTool(allowedRoots: [
                    URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Documents", isDirectory: true),
                    Self.userAgentsRootDirectory(),
                ]),
                // Filesystem write + listing share fs.read's sandbox
                // so any file an agent can read it can also list /
                // write a sibling of. Tools are otherwise independent
                // — fs.write doesn't depend on fs.read having been
                // called, etc.
                FilesystemWriteTool(allowedRoots: [
                    URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Documents", isDirectory: true),
                    Self.userAgentsRootDirectory(),
                ]),
                FilesystemListTool(allowedRoots: [
                    URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Documents", isDirectory: true),
                    Self.userAgentsRootDirectory(),
                ]),
                // Spreadsheet writers — same sandbox as fs.write.
                // csv.write covers the broad "any spreadsheet program"
                // workflow; tsv.write is the right shape for paste-
                // into-cells flows; xlsx.write produces a real Excel
                // workbook with multi-sheet, formulas, and bold-header
                // formatting via libxlsxwriter.
                CSVWriteTool(allowedRoots: [
                    URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Documents", isDirectory: true),
                    Self.userAgentsRootDirectory(),
                ]),
                TSVWriteTool(allowedRoots: [
                    URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Documents", isDirectory: true),
                    Self.userAgentsRootDirectory(),
                ]),
                XlsxWriteTool(allowedRoots: [
                    URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Documents", isDirectory: true),
                    Self.userAgentsRootDirectory(),
                ]),
                // Pure-Swift xlsx reader (CoreXLSX). Pairs with
                // xlsx.write for the round-trip — libxlsxwriter is
                // write-only, CoreXLSX is read-only, so we use both.
                XlsxReadTool(allowedRoots: [
                    URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Documents", isDirectory: true),
                    Self.userAgentsRootDirectory(),
                ]),
                // PDF text extraction. Same sandbox as `fs.read` —
                // PDFs the user wants the agent to read live in
                // ~/Documents most of the time; persona-bundled PDFs
                // (rare) live under the agents root.
                PDFExtractTool(allowedRoots: [
                    URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Documents", isDirectory: true),
                    Self.userAgentsRootDirectory(),
                ]),
                // Clipboard read/write. Wired to the system pasteboard
                // (`NSPasteboard.general`); tests use a private
                // pasteboard so they don't trample the user's clipboard.
                ClipboardGetTool(),
                ClipboardSetTool(),
                // Deterministic calculator. Models — especially small
                // ones — silently miscompute multi-step arithmetic;
                // exposing this as a tool eliminates that failure mode
                // for any agent that opts into it.
                MathComputeTool(),
                URLFetchTool(allowedHosts: [
                    "en.wikipedia.org",
                    "raw.githubusercontent.com",
                ]),
                // Web search. Backend chosen by `searxngEndpoint`
                // setting — empty/nil = DDG fallback (no setup),
                // non-empty = SearXNG JSON. Re-registered on settings
                // change in `applySettings` so flipping the endpoint
                // takes effect on the next call without an app restart.
                WebSearchTool(searxngEndpoint: settings.searxngEndpoint),
                // Wikipedia tools — search + clean-text article fetch
                // via the MediaWiki Action API. Distinct from
                // `web.search` + `http.fetch` because: (a) Wikipedia's
                // search API is more direct than scraping a SERP for
                // wiki hits, and (b) the `extracts` endpoint returns
                // chrome-stripped article text where `http.fetch`
                // returns the full HTML and truncates at 256 KB.
                WikipediaSearchTool(),
                WikipediaArticleTool(),
                VaultSearchTool(retriever: retriever),
            ])
            // Plugins (compile-time, generated from
            // `projects/plugins/plugins.json`). Runs after the built-in
            // tools so plugin tools join the same merged catalog, and
            // before the MCP bootstrap so the system-prompt tool
            // section sees both. Each plugin's `register` returns the
            // tools it contributes; the host registers them. Per-plugin
            // failures are caught + logged; remaining plugins still
            // load.
            let pluginResult = await PluginLoader.loadAll(
                types: allPluginTypes,
                configs: pluginConfigs
            )
            for (id, contrib) in pluginResult.contributions {
                for tool in contrib.tools {
                    await registry.register(tool)
                }
                let toolCount = contrib.tools.count
                if toolCount > 0 {
                    logs.log(
                        .info,
                        source: "plugins",
                        message: "plugin \(id) registered \(toolCount) tool\(toolCount == 1 ? "" : "s")"
                    )
                }
            }
            for failure in pluginResult.failures {
                logs.log(
                    .error,
                    source: "plugins",
                    message: "plugin \(failure.pluginID) failed to register",
                    payload: failure.message
                )
            }
            // MCP servers (item 11). Each `*.json` under the user's
            // mcp directory describes one subprocess to spawn; tools
            // discovered via `initialize` + `tools/list` register
            // into the same `ToolRegistry` as the builtins under
            // `mcp.<server>.<tool>` names. Per-server failures
            // surface as Console diagnostics; the rest of the
            // bootstrap continues so a broken server doesn't
            // blackhole the agent layer.
            let mcpDiagnostics = await mcpHost.bootstrap(
                directory: Self.userMCPDirectory(),
                into: registry,
                clientName: "infer",
                clientVersion: "0.1.6",
                stderrSink: { line in
                    logs.logFromBackground(
                        .info,
                        source: "mcp.stderr",
                        message: line
                    )
                }
            )
            for diag in mcpDiagnostics {
                let level: LogLevel
                switch diag.severity {
                case .error: level = .error
                case .warning: level = .warning
                case .skipped: level = .info
                }
                logs.log(
                    level,
                    source: "mcp",
                    message: "\(diag.serverID): \(diag.message)"
                )
            }
            // Mirror the host's per-server summary into an
            // @Observable property the Agents-tab UI binds to.
            // Capturing `self` weakly is overkill — bootstrap runs
            // once at app start and the VM lives the whole session.
            let summaries = await mcpHost.summaries
            await MainActor.run { [weak self] in
                self?.mcpServers = summaries
                self?.mcpDiagnostics = mcpDiagnostics
            }
            let specs = await registry.allSpecs()
            let catalog = ToolCatalog(tools: specs)
            await controller.bootstrap(
                settings: settings,
                firstPartyPersonas: firstParty,
                personasDirectories: [
                    Self.userPersonasDirectory(),
                    Self.userAgentsDirectory(),
                ],
                toolCatalog: catalog,
                retriever: retriever
            )
            // Surface per-file parse failures into the Console so they
            // show up in the live observability view, not just the
            // one-time Agents-tab banner. The banner stays as the
            // persistent surface; the Console adds a time-ordered
            // record across all bootstraps.
            let diagnostics = controller.libraryDiagnostics
            for diag in diagnostics {
                logs.log(
                    .warning,
                    source: "agents",
                    message: "skipped \(diag.url.lastPathComponent)",
                    payload: diag.message
                )
            }
            let count = controller.availableAgents.count
            logs.log(
                .info,
                source: "agents",
                message: "loaded \(count) agent\(count == 1 ? "" : "s")"
            )
        }
    }

    // MARK: - Switching

    /// Swap the active agent for the current conversation. Delegates
    /// state to the controller and applies the returned effects to the
    /// VM (transcript, runners, vault id).
    func switchAgent(to listing: AgentListing) {
        let currentBackend = self.currentBackendPreference
        let settings = self.settings
        Task { [controller = self.agentController] in
            let effects = await controller.switchAgent(
                to: listing,
                currentBackend: currentBackend,
                settings: settings
            )
            await MainActor.run {
                self.apply(effects)
                if !effects.isEmpty {
                    self.logs.log(
                        .info,
                        source: "agents",
                        message: "switched to \(listing.name)"
                    )
                }
            }
        }
    }

    // MARK: - Effect application

    /// Apply one batch of effects from the controller in order.
    ///
    /// Kept deliberately small: one-line translation per case. Business
    /// logic lives in the controller where it's unit-tested. The one
    /// piece of adapter-side state is `currentPrompt`, tracked so that a
    /// `.pushSampling` effect following a `.pushSystemPrompt` in the
    /// same batch sees the new prompt when calling MLX (which bundles
    /// prompt and sampling in one API).
    func apply(_ effects: [AgentEffect]) {
        var currentPrompt: String? =
            settings.systemPrompt.isEmpty ? nil : settings.systemPrompt
        for effect in effects {
            switch effect {
            case .insertDivider(let agentName):
                messages.append(ChatMessage(
                    role: .system,
                    kind: .agentDivider(agentName: agentName),
                    text: "Switched to \(agentName)"
                ))
            case .invalidateConversation:
                currentConversationId = nil
            case .resetTranscript:
                messages.removeAll()
                currentConversationId = nil
            case .pushSystemPrompt(let prompt):
                currentPrompt = prompt
                let llama = self.llama
                Task { await llama.setSystemPrompt(prompt) }
            case .pushSampling(let temperature, let topP, let seed):
                let temp = Float(temperature)
                let top = Float(topP)
                let llama = self.llama
                let mlx = self.mlx
                let promptForMLX = currentPrompt ?? ""
                Task {
                    await llama.updateSampling(
                        temperature: temp, topP: top, topK: 40, seed: seed
                    )
                    await mlx.updateSettings(
                        systemPrompt: promptForMLX,
                        temperature: temp,
                        topP: top,
                        seed: seed
                    )
                }
            }
        }
    }

    /// View-model's live backend mapped into the agent-layer enum.
    var currentBackendPreference: BackendPreference {
        switch backend {
        case .llama: return .llama
        case .mlx: return .mlx
        }
    }

    // MARK: - Agents-tab actions

    /// Open the user agents root folder in Finder, creating both the
    /// `personas/` and `agents/` subdirectories if missing. Used by the
    /// Reveal-folder button in the Agents tab; the root view shows both
    /// subdirs so users discover the split.
    func revealUserAgentsFolder() {
        let root = Self.userAgentsRootDirectory()
        let fm = FileManager.default
        for sub in [Self.userPersonasDirectory(), Self.userAgentsDirectory()] {
            if !fm.fileExists(atPath: sub.path) {
                try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    /// Read-only snapshot of an agent's configuration, resolved on
    /// demand for the inspector UI. Populated either from the synthetic
    /// Default row (driven by `InferSettings`) or from the registered
    /// `PromptAgent` JSON payload. Compiled `Agent` conformances with
    /// no JSON representation return a sparse snapshot (prompt missing)
    /// so the UI can still render backend/tool/decoding info.
    struct AgentSnapshot {
        let listing: AgentListing
        let systemPrompt: String?
        let decoding: DecodingParams
        let toolsAllow: [ToolName]
        let toolsDeny: [ToolName]
        /// Tools from the live catalog that would be exposed to this
        /// agent if it became active under the current backend. Computed
        /// by applying `toolsAllow` / `toolsDeny` to the catalog.
        let exposedTools: [ToolSpec]
    }

    /// Compute a snapshot of `listing` for display in the inspector.
    /// Returns nil only for compiled agents with no JSON backing that
    /// are also not the Default (none today — reserved for the future).
    func inspectorSnapshot(for listing: AgentListing) async -> AgentSnapshot? {
        let catalog = agentController.toolCatalog
        if listing.isDefault {
            return AgentSnapshot(
                listing: listing,
                systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt,
                decoding: DecodingParams(from: settings),
                toolsAllow: [],
                toolsDeny: [],
                exposedTools: []  // Default has no tools in PR 2
            )
        }
        guard let agent = await agentController.registry.agent(id: listing.id) else {
            return nil
        }
        let prompt: String?
        let decoding: DecodingParams
        let allow: [ToolName]
        let deny: [ToolName]
        if let p = agent as? PromptAgent {
            prompt = p.promptText
            decoding = p.defaultDecodingParams
            allow = p.requirements.toolsAllow
            deny = p.requirements.toolsDeny
        } else {
            prompt = nil
            decoding = agent.decodingParams(for: AgentContext(
                runner: RunnerHandle(
                    backend: currentBackendPreference,
                    templateFamily: nil,
                    maxContext: 0,
                    currentTokenCount: 0
                ),
                tools: catalog
            ))
            allow = []
            deny = []
        }
        let exposed = catalog.tools.filter { spec in
            if deny.contains(spec.name) { return false }
            if allow.isEmpty { return true }
            return allow.contains(spec.name)
        }
        return AgentSnapshot(
            listing: listing,
            systemPrompt: prompt,
            decoding: decoding,
            toolsAllow: allow,
            toolsDeny: deny,
            exposedTools: exposed
        )
    }

    /// Locate the on-disk JSON backing a user persona/agent by scanning
    /// both user subdirectories (`personas/`, `agents/`) and decoding
    /// each file's id. Returns nil when the id is not user-authored,
    /// when no file matches, or when the directories cannot be read.
    /// Used by Reveal/Delete actions.
    func userPersonaURL(for id: AgentID) -> URL? {
        let dirs = [Self.userPersonasDirectory(), Self.userAgentsDirectory()]
        let fm = FileManager.default
        for dir in dirs {
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.pathExtension.lowercased() == "json" {
                guard let agent = try? AgentRegistry.decodePersona(at: url)
                else { continue }
                if agent.id == id { return url }
            }
        }
        return nil
    }

    /// Move a user persona to the Trash and refresh listings. No-op for
    /// non-user personas (only user-authored files are user-owned). The
    /// caller (sidebar row) is responsible for confirmation. Safe under
    /// concurrent reads — `NSWorkspace.recycle` is async but we only
    /// refresh listings after it completes.
    func deleteUserPersona(_ listing: AgentListing) {
        guard listing.source == .user, !listing.isDefault else { return }
        guard let url = userPersonaURL(for: listing.id) else {
            errorMessage = "Could not locate the JSON file for \(listing.name)."
            return
        }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.errorMessage = "Failed to delete: \(error.localizedDescription)"
                    return
                }
                self.bootstrapAgents()
                self.toasts.show("Moved \"\(listing.name)\" to Trash.")
            }
        }
    }

    /// Re-run the controller bootstrap so any edits the user made to
    /// JSON files in the user agents folder become visible without
    /// relaunching the app. Re-registers built-in tools (harmless
    /// because registration is idempotent by name).
    func reloadAgents() {
        bootstrapAgents()
    }

    // MARK: - MCP server actions (Agents tab)

    /// Open the user MCP config folder in Finder, creating it if
    /// missing so the user lands on a real directory rather than a
    /// "no such folder" dialog.
    func revealMCPFolder() {
        let dir = Self.userMCPDirectory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Approve a server through the host's store and trigger a
    /// reload so the now-approved server actually launches. Both
    /// halves matter: persistence so the answer survives restart;
    /// reload so the user sees the consequence immediately.
    func approveMCPServer(id: String) {
        Task { [weak self, mcpHost = self.mcpHost] in
            await mcpHost.approve(serverID: id)
            await self?.reloadMCPServers()
        }
    }

    /// Revoke approval and reload — the running client (if any) gets
    /// shut down, its tools unregister from the registry, and the
    /// summary flips to `.denied`.
    func revokeMCPServer(id: String) {
        Task { [weak self, mcpHost = self.mcpHost] in
            await mcpHost.revoke(serverID: id)
            await self?.reloadMCPServers()
        }
    }

    /// Re-scan the MCP config directory and re-launch the approved
    /// servers. Disables the reload button while in flight so the
    /// user can't double-trigger a torrent of subprocess churn.
    func reloadMCPServers() async {
        await MainActor.run { self.mcpReloading = true }
        let logs = self.logs
        let diagnostics = await self.mcpHost.reload(
            directory: Self.userMCPDirectory(),
            into: self.toolRegistry,
            clientName: "infer",
            clientVersion: "0.1.6",
            stderrSink: { line in
                logs.logFromBackground(.info, source: "mcp.stderr", message: line)
            }
        )
        for diag in diagnostics {
            let level: LogLevel
            switch diag.severity {
            case .error: level = .error
            case .warning: level = .warning
            case .skipped: level = .info
            }
            logs.log(level, source: "mcp", message: "\(diag.serverID): \(diag.message)")
        }
        let summaries = await self.mcpHost.summaries
        await MainActor.run {
            self.mcpServers = summaries
            self.mcpDiagnostics = diagnostics
            self.mcpReloading = false
        }
    }

    /// Write a copy of `listing` to the user agents folder as a
    /// PromptAgent JSON, then reveal it in Finder. For compiled Agent
    /// conformances without a JSON representation (none currently
    /// except `DefaultAgent`), we synthesise a persona from the
    /// agent's live state.
    func duplicatePersona(_ listing: AgentListing) async {
        let agent: (any Agent)?
        if listing.id == DefaultAgent.id {
            agent = DefaultAgent(settings: settings)
        } else {
            agent = await agentController.registry.agent(id: listing.id)
        }
        guard let agent else { return }

        let timestamp = Int(Date().timeIntervalSince1970)
        let copyId = AgentID("\(listing.id).copy.\(timestamp)")
        let copyName = "\(listing.name) (copy)"

        let payload: PromptAgent
        if let prompt = agent as? PromptAgent {
            payload = PromptAgent(
                id: copyId,
                kind: prompt.kind,
                metadata: AgentMetadata(
                    name: copyName,
                    description: prompt.metadata.description,
                    icon: prompt.metadata.icon,
                    author: "user"
                ),
                requirements: prompt.requirements,
                decodingParams: prompt.defaultDecodingParams,
                systemPrompt: prompt.authoredSystemPrompt,
                contextPath: prompt.contextPath,
                chain: prompt.chain,
                orchestrator: prompt.orchestrator
            )
        } else if let def = agent as? DefaultAgent {
            payload = PromptAgent(
                id: copyId,
                kind: .persona,
                metadata: AgentMetadata(
                    name: copyName,
                    description: "Copy of the live Default agent at duplicate time.",
                    author: "user"
                ),
                requirements: AgentRequirements(),
                decodingParams: DecodingParams(from: def.settings),
                systemPrompt: def.settings.systemPrompt
            )
        } else {
            // Compiled conformance with no JSON rep — skip.
            return
        }

        let dir = (payload.kind == .agent)
            ? Self.userAgentsDirectory()
            : Self.userPersonasDirectory()
        let fileName = copyId.rawValue.replacingOccurrences(of: "/", with: "_")
        let fileURL = dir.appendingPathComponent("\(fileName).json")
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL)
        } catch {
            errorMessage = "Failed to write persona: \(error.localizedDescription)"
            return
        }

        bootstrapAgents()
        toasts.show(
            "Duplicated \"\(listing.name)\" → \(fileURL.lastPathComponent)",
            actionTitle: "Reveal",
            action: {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        )
    }
}
