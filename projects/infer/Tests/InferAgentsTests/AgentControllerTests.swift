import XCTest
@testable import InferAgents
@testable import InferCore

@MainActor
final class AgentControllerTests: XCTestCase {
    private func makeController() -> AgentController {
        AgentController(registry: AgentRegistry())
    }

    private func listing(
        id: AgentID = "p",
        name: String = "Persona",
        backend: BackendPreference = .any,
        source: AgentSource = .user,
        kind: AgentKind = .persona,
        isDefault: Bool = false
    ) -> AgentListing {
        AgentListing(
            id: id,
            name: name,
            description: "",
            source: source,
            backend: backend,
            templateFamily: nil,
            kind: kind,
            isDefault: isDefault
        )
    }

    private var defaultListing: AgentListing {
        listing(id: DefaultAgent.id, name: "Default", source: .firstParty, isDefault: true)
    }

    // MARK: - Bootstrap

    func testBootstrapSeedsDefaultDecodingParams() async {
        let c = makeController()
        let s = InferSettings(systemPrompt: "", temperature: 0.42, topP: 0.77, maxTokens: 128)
        await c.bootstrap(settings: s, personasDirectory: nil)
        XCTAssertEqual(c.activeDecodingParams, DecodingParams(from: s))
    }

    func testBootstrapRefreshesListingsIncludingDefault() async {
        let c = makeController()
        await c.bootstrap(settings: .defaults, personasDirectory: nil)
        XCTAssertEqual(c.availableAgents.first?.isDefault, true)
        XCTAssertEqual(c.availableAgents.first?.id, DefaultAgent.id)
    }

    func testBootstrapLoadsFirstPartyPersonasFromBundledURLs() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let good = tmp.appendingPathComponent("good.json")
        try """
        {
          "schemaVersion": 1,
          "id": "fp.good",
          "metadata": {"name": "FP Good"},
          "systemPrompt": "ok"
        }
        """.data(using: .utf8)!.write(to: good)

        let bad = tmp.appendingPathComponent("bad.json")
        try """
        {"schemaVersion": 1, "id": "fp.bad", "metadata": {"name": "FP Bad"}}
        """.data(using: .utf8)!.write(to: bad)  // missing systemPrompt

        let c = makeController()
        await c.bootstrap(
            settings: .defaults,
            firstPartyPersonas: [good, bad],
            personasDirectory: nil
        )

        let ids = c.availableAgents.map(\.id)
        XCTAssertEqual(ids, [DefaultAgent.id, "fp.good"])

        // The registered agent is tagged first-party, not user.
        let entry = await c.registry.entry(id: "fp.good")
        XCTAssertEqual(entry?.source, .firstParty)
    }

    func testBootstrapPublishesLibraryDiagnostics() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // One well-formed file; one malformed (missing systemPrompt).
        let good = tmp.appendingPathComponent("good.json")
        try """
        {
          "schemaVersion": 1,
          "id": "u.good",
          "metadata": {"name": "U Good"},
          "systemPrompt": "ok"
        }
        """.data(using: .utf8)!.write(to: good)
        let bad = tmp.appendingPathComponent("bad.json")
        try """
        {"schemaVersion": 1, "id": "u.bad", "metadata": {"name": "U Bad"}}
        """.data(using: .utf8)!.write(to: bad)

        let c = makeController()
        await c.bootstrap(
            settings: .defaults,
            firstPartyPersonas: [],
            personasDirectory: tmp
        )

        // The good file loaded; the bad file surfaces in diagnostics.
        XCTAssertTrue(c.availableAgents.contains { $0.id == "u.good" })
        XCTAssertFalse(c.availableAgents.contains { $0.id == "u.bad" })
        XCTAssertEqual(c.libraryDiagnostics.count, 1)
        XCTAssertEqual(c.libraryDiagnostics.first?.url.lastPathComponent, "bad.json")
    }

    func testBootstrapResetsDiagnosticsOnReload() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diag2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bad = tmp.appendingPathComponent("bad.json")
        try "{ not json }".data(using: .utf8)!.write(to: bad)

        let c = makeController()
        await c.bootstrap(settings: .defaults, personasDirectory: tmp)
        XCTAssertEqual(c.libraryDiagnostics.count, 1)

        // User fixes the file; next bootstrap should clear diagnostics.
        try """
        {"schemaVersion": 1, "id": "u.fixed", "metadata": {"name": "Fixed"}, "systemPrompt": "hi"}
        """.data(using: .utf8)!.write(to: bad)
        await c.bootstrap(settings: .defaults, personasDirectory: tmp)
        XCTAssertTrue(c.libraryDiagnostics.isEmpty)
    }

    func testFirstPartyDoesNotOverrideUserOnCollision() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("col-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let userFile = tmp.appendingPathComponent("same.json")
        try """
        {
          "schemaVersion": 1,
          "id": "same",
          "metadata": {"name": "User version"},
          "systemPrompt": "from user"
        }
        """.data(using: .utf8)!.write(to: userFile)

        let fpFile = tmp.appendingPathComponent("same-fp.json")
        try """
        {
          "schemaVersion": 1,
          "id": "same",
          "metadata": {"name": "First-party version"},
          "systemPrompt": "from fp"
        }
        """.data(using: .utf8)!.write(to: fpFile)

        let c = makeController()
        await c.bootstrap(
            settings: .defaults,
            firstPartyPersonas: [fpFile],
            personasDirectory: tmp
        )

        // User precedence wins on id collision; the listing's name comes
        // from the user file even though first-party loads first.
        let entry = await c.registry.entry(id: "same")
        XCTAssertEqual(entry?.source, .user)
        XCTAssertEqual(entry?.agent.metadata.name, "User version")
    }

    func testBootstrapLoadsUserPersonasFromDirectory() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ctrl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try """
        {
          "schemaVersion": 1,
          "id": "loaded",
          "metadata": {"name": "Loaded"},
          "systemPrompt": "hi"
        }
        """.data(using: .utf8)!.write(to: tmp.appendingPathComponent("loaded.json"))

        let c = makeController()
        await c.bootstrap(settings: .defaults, personasDirectory: tmp)

        let ids = c.availableAgents.map(\.id)
        XCTAssertEqual(ids, [DefaultAgent.id, "loaded"])
    }

    // MARK: - refreshListings ordering

    func testRefreshListingsPlacesDefaultFirstAndSortsRest() async {
        let reg = AgentRegistry()
        await reg.register(FakeAgent(id: "z-first", name: "Zeta"), source: .firstParty)
        await reg.register(FakeAgent(id: "a-plug", name: "Alpha"), source: .plugin)
        await reg.register(FakeAgent(id: "b-user", name: "Beta"), source: .user)
        await reg.register(FakeAgent(id: "a-user", name: "Aardvark"), source: .user)

        let c = AgentController(registry: reg)
        await c.refreshListings()

        // Expected: Default, then user (sorted by name), then plugin, then firstParty.
        let ids = c.availableAgents.map(\.id)
        XCTAssertEqual(ids, [DefaultAgent.id, "a-user", "b-user", "a-plug", "z-first"])
    }

    // MARK: - Compatibility

    func testIsCompatibleMatrix() {
        let c = makeController()
        let any_ = listing(backend: .any)
        let lla = listing(backend: .llama)
        let mlx = listing(backend: .mlx)

        XCTAssertTrue(c.isCompatible(any_, backend: .llama))
        XCTAssertTrue(c.isCompatible(any_, backend: .mlx))
        XCTAssertTrue(c.isCompatible(lla, backend: .llama))
        XCTAssertFalse(c.isCompatible(lla, backend: .mlx))
        XCTAssertFalse(c.isCompatible(mlx, backend: .llama))
        XCTAssertTrue(c.isCompatible(mlx, backend: .mlx))
    }

    func testIncompatibilityReasonStrings() {
        let c = makeController()
        // .any always compatible, so no reason regardless of current backend.
        XCTAssertEqual(c.incompatibilityReason(listing(backend: .any), backend: .llama), "")
        // Backend mismatch returns the requirement.
        XCTAssertEqual(c.incompatibilityReason(listing(backend: .llama), backend: .mlx), "Requires llama.cpp backend")
        XCTAssertEqual(c.incompatibilityReason(listing(backend: .mlx), backend: .llama), "Requires MLX backend")
        // Backend match — no reason (template not declared on this listing).
        XCTAssertEqual(c.incompatibilityReason(listing(backend: .llama), backend: .llama), "")
    }

    // MARK: - switchAgent effects

    func testSwitchToSameAgentIsNoOp() async {
        let c = makeController()
        await c.bootstrap(settings: .defaults, personasDirectory: nil)
        let effects = await c.switchAgent(
            to: defaultListing,
            currentBackend: .llama,
            settings: .defaults
        )
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(c.activeAgentId, DefaultAgent.id)
    }

    func testSwitchToIncompatibleIsNoOp() async {
        let reg = AgentRegistry()
        await reg.register(FakeAgent(id: "m", name: "MLX only", backend: .mlx), source: .user)
        let c = AgentController(registry: reg)
        await c.bootstrap(settings: .defaults, personasDirectory: nil)

        let mlxOnly = listing(id: "m", name: "MLX only", backend: .mlx)
        let effects = await c.switchAgent(
            to: mlxOnly,
            currentBackend: .llama,
            settings: .defaults
        )
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(c.activeAgentId, DefaultAgent.id)
    }

    func testSwitchToPromptAgentEmitsEffectsInOrder() async {
        let reg = AgentRegistry()
        await reg.register(
            PromptAgent(
                id: "reviewer",
                metadata: AgentMetadata(name: "Reviewer"),
                requirements: AgentRequirements(backend: .any),
                decodingParams: DecodingParams(temperature: 0.2, topP: 0.9, maxTokens: 2048),
                systemPrompt: "be terse"
            ),
            source: .user
        )
        let c = AgentController(registry: reg)
        await c.bootstrap(settings: .defaults, personasDirectory: nil)

        let target = listing(id: "reviewer", name: "Reviewer")
        let effects = await c.switchAgent(
            to: target,
            currentBackend: .llama,
            settings: InferSettings.defaults
        )

        guard effects.count == 4 else {
            return XCTFail("expected 4 effects, got \(effects)")
        }
        XCTAssertEqual(effects[0], .insertDivider(agentName: "Reviewer"))
        XCTAssertEqual(effects[1], .invalidateConversation)
        XCTAssertEqual(effects[2], .pushSystemPrompt("be terse"))
        XCTAssertEqual(
            effects[3],
            .pushSampling(temperature: 0.2, topP: 0.9, seed: nil)
        )
    }

    func testSwitchUpdatesActiveAgentIdAndParams() async {
        let reg = AgentRegistry()
        await reg.register(
            PromptAgent(
                id: "r",
                metadata: AgentMetadata(name: "R"),
                decodingParams: DecodingParams(temperature: 0.3, topP: 0.5, maxTokens: 64),
                systemPrompt: "p"
            ),
            source: .user
        )
        let c = AgentController(registry: reg)
        await c.bootstrap(settings: .defaults, personasDirectory: nil)

        _ = await c.switchAgent(
            to: listing(id: "r", name: "R"),
            currentBackend: .llama,
            settings: .defaults
        )

        XCTAssertEqual(c.activeAgentId, "r")
        XCTAssertEqual(c.activeDecodingParams, DecodingParams(temperature: 0.3, topP: 0.5, maxTokens: 64))
    }

    func testSwitchToDefaultUsesLiveSettingsForDecodingParams() async {
        let reg = AgentRegistry()
        await reg.register(
            PromptAgent(
                id: "r",
                metadata: AgentMetadata(name: "R"),
                decodingParams: DecodingParams(temperature: 0.1, topP: 0.1, maxTokens: 8),
                systemPrompt: "p"
            ),
            source: .user
        )
        let c = AgentController(registry: reg)
        await c.bootstrap(settings: .defaults, personasDirectory: nil)

        _ = await c.switchAgent(
            to: listing(id: "r", name: "R"),
            currentBackend: .llama,
            settings: .defaults
        )
        XCTAssertEqual(c.activeAgentId, "r")

        // Switch back to Default under custom settings.
        let custom = InferSettings(
            systemPrompt: "live",
            temperature: 0.9,
            topP: 0.5,
            maxTokens: 321
        )
        _ = await c.switchAgent(
            to: defaultListing,
            currentBackend: .llama,
            settings: custom
        )
        XCTAssertEqual(c.activeAgentId, DefaultAgent.id)
        XCTAssertEqual(c.activeDecodingParams, DecodingParams(from: custom))
    }

    // MARK: - applySettings

    func testApplySettingsWhileDefaultActiveEmitsSamplingOnly() async {
        let c = makeController()
        await c.bootstrap(settings: .defaults, personasDirectory: nil)
        let prev = InferSettings.defaults
        var new = prev
        new.temperature = 0.1
        new.topP = 0.2
        let effects = c.applySettings(new, previous: prev)
        XCTAssertEqual(effects, [.pushSampling(temperature: 0.1, topP: 0.2, seed: nil)])
    }

    func testApplySettingsPromptChangeOrdersSystemPromptBeforeSampling() async {
        // Order matters: pushSystemPrompt must land before pushSampling so
        // that the adapter's MLX update (which bundles prompt + sampling)
        // sees the new prompt, not the stale one. resetTranscript comes
        // last so a mid-batch crash doesn't lose the transcript before
        // the runner has been updated.
        let c = makeController()
        await c.bootstrap(settings: .defaults, personasDirectory: nil)
        let prev = InferSettings.defaults
        var new = prev
        new.systemPrompt = "something new"
        let effects = c.applySettings(new, previous: prev)
        XCTAssertEqual(effects, [
            .pushSystemPrompt("something new"),
            .pushSampling(temperature: new.temperature, topP: new.topP, seed: nil),
            .resetTranscript,
        ])
    }

    func testApplySettingsEmptyPromptPushesNilClear() async {
        let c = makeController()
        await c.bootstrap(settings: .defaults, personasDirectory: nil)
        let prev = InferSettings(systemPrompt: "old", temperature: 0.5, topP: 0.5, maxTokens: 64)
        let new = InferSettings(systemPrompt: "", temperature: 0.5, topP: 0.5, maxTokens: 64)
        let effects = c.applySettings(new, previous: prev)
        XCTAssertTrue(effects.contains(.pushSystemPrompt(nil)))
        XCTAssertTrue(effects.contains(.resetTranscript))
    }

    func testApplySettingsNonDefaultActiveReturnsEmpty() async {
        let reg = AgentRegistry()
        await reg.register(
            PromptAgent(
                id: "r",
                metadata: AgentMetadata(name: "R"),
                systemPrompt: "p"
            ),
            source: .user
        )
        let c = AgentController(registry: reg)
        await c.bootstrap(settings: .defaults, personasDirectory: nil)
        _ = await c.switchAgent(
            to: listing(id: "r", name: "R"),
            currentBackend: .llama,
            settings: .defaults
        )

        let prev = InferSettings.defaults
        var new = prev
        new.temperature = 1.2
        new.systemPrompt = "would reset under Default"
        let effects = c.applySettings(new, previous: prev)
        XCTAssertTrue(effects.isEmpty)
    }

    func testApplySettingsDoesNotChangeCachedParamsUnderNonDefault() async {
        let reg = AgentRegistry()
        let pinned = DecodingParams(temperature: 0.3, topP: 0.7, maxTokens: 128)
        await reg.register(
            PromptAgent(
                id: "r",
                metadata: AgentMetadata(name: "R"),
                decodingParams: pinned,
                systemPrompt: "p"
            ),
            source: .user
        )
        let c = AgentController(registry: reg)
        await c.bootstrap(settings: .defaults, personasDirectory: nil)
        _ = await c.switchAgent(
            to: listing(id: "r", name: "R"),
            currentBackend: .llama,
            settings: .defaults
        )
        XCTAssertEqual(c.activeDecodingParams, pinned)

        let prev = InferSettings.defaults
        var new = prev
        new.temperature = 1.8
        _ = c.applySettings(new, previous: prev)
        XCTAssertEqual(c.activeDecodingParams, pinned, "non-Default cache must not track Default slider")
    }

    // MARK: - activeAgentName

    func testActiveAgentNameDefaultsToDefault() async {
        let c = makeController()
        await c.bootstrap(settings: .defaults, personasDirectory: nil)
        XCTAssertEqual(c.activeAgentName(), "Default")
    }

    func testActiveAgentNameResolvesFromListings() async {
        let reg = AgentRegistry()
        await reg.register(FakeAgent(id: "alpha", name: "Alpha Agent"), source: .user)
        let c = AgentController(registry: reg)
        await c.bootstrap(settings: .defaults, personasDirectory: nil)
        _ = await c.switchAgent(
            to: listing(id: "alpha", name: "Alpha Agent"),
            currentBackend: .llama,
            settings: .defaults
        )
        XCTAssertEqual(c.activeAgentName(), "Alpha Agent")
    }
}

// MARK: - helpers

private struct FakeAgent: Agent {
    let id: AgentID
    let metadata: AgentMetadata
    let requirements: AgentRequirements

    init(id: AgentID, name: String, backend: BackendPreference = .any) {
        self.id = id
        self.metadata = AgentMetadata(name: name)
        self.requirements = AgentRequirements(backend: backend)
    }

    func decodingParams(for context: AgentContext) -> DecodingParams {
        DecodingParams(from: .defaults)
    }
    func systemPrompt(for context: AgentContext) async throws -> String { "" }
}
