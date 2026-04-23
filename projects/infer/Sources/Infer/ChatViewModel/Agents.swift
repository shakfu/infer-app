import Foundation
import AppKit
import InferAgents
import InferCore

extension ChatViewModel {
    /// Directory where user-authored JSON personas live.
    /// `~/Library/Application Support/Infer/agents/`.
    static func userAgentsDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Infer", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
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
        agentController.incompatibilityReason(listing)
    }

    func activeAgentName() -> String { agentController.activeAgentName() }

    // MARK: - Lifecycle

    /// Resolve URLs of bundled first-party personas. Looks inside
    /// `Bundle.module` (the SwiftPM-generated resource bundle for this
    /// target) under the `agents` subdirectory — same path used by
    /// `.copy("Resources/agents")` in `Package.swift`.
    static func firstPartyPersonaURLs() -> [URL] {
        Bundle.module.urls(
            forResourcesWithExtension: "json",
            subdirectory: "agents"
        ) ?? []
    }

    /// Called from `ChatViewModel.init`. Seeds cached decoding params
    /// synchronously then kicks off async persona discovery, tool
    /// registration, and catalog publication to the controller.
    func bootstrapAgents() {
        let firstParty = Self.firstPartyPersonaURLs()
        Task { [controller = self.agentController, registry = self.toolRegistry, settings = self.settings] in
            // Register the PR 2 built-ins. Tool registrations and the
            // controller bootstrap happen in the same task so the
            // first switchAgent after launch sees a populated catalog.
            await registry.register([
                ClockNowTool(),
                WordCountTool(),
            ])
            let specs = await registry.allSpecs()
            let catalog = ToolCatalog(tools: specs)
            await controller.bootstrap(
                settings: settings,
                firstPartyPersonas: firstParty,
                personasDirectory: Self.userAgentsDirectory(),
                toolCatalog: catalog
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
            await MainActor.run { self.apply(effects) }
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

    /// Open the user agents folder in Finder, creating it if missing.
    /// Used by the Reveal-folder button in the Agents tab.
    func revealUserAgentsFolder() {
        let url = Self.userAgentsDirectory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

    /// Locate the on-disk JSON backing a user persona by scanning the
    /// user agents directory and decoding each file's id. Returns nil
    /// when the id is not a user persona, when no file matches, or when
    /// the directory cannot be read. Used by Reveal/Delete actions.
    func userPersonaURL(for id: AgentID) -> URL? {
        let dir = Self.userAgentsDirectory()
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let agent = try? decoder.decode(PromptAgent.self, from: data)
            else { continue }
            if agent.id == id { return url }
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
        let copyId = "\(listing.id).copy.\(timestamp)"
        let copyName = "\(listing.name) (copy)"

        let payload: PromptAgent
        if let prompt = agent as? PromptAgent {
            payload = PromptAgent(
                id: copyId,
                metadata: AgentMetadata(
                    name: copyName,
                    description: prompt.metadata.description,
                    icon: prompt.metadata.icon,
                    author: "user"
                ),
                requirements: prompt.requirements,
                decodingParams: prompt.defaultDecodingParams,
                systemPrompt: prompt.promptText
            )
        } else if let def = agent as? DefaultAgent {
            payload = PromptAgent(
                id: copyId,
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

        let dir = Self.userAgentsDirectory()
        let fileName = copyId.replacingOccurrences(of: "/", with: "_")
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
