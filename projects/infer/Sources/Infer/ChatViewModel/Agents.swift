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
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
