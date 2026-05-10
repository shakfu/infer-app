import XCTest
@testable import InferAppCore

final class WorkspaceParamCascadeTests: XCTestCase {

    // MARK: - Two-layer cascade resolution

    func testBothLayersNilProducesAllNil() {
        let r = WorkspaceParamCascade.resolve(active: nil, defaults: nil)
        XCTAssertNil(r.systemPrompt)
        XCTAssertNil(r.temperature)
        XCTAssertNil(r.topP)
        XCTAssertNil(r.maxTokens)
    }

    func testNilActiveFallsThroughToDefaults() {
        let defaults = WorkspaceParamCascade(
            systemPrompt: "be helpful",
            temperature: 0.7,
            topP: 0.95,
            maxTokens: 1024
        )
        let r = WorkspaceParamCascade.resolve(active: nil, defaults: defaults)
        XCTAssertEqual(r.systemPrompt, "be helpful")
        XCTAssertEqual(r.temperature, 0.7)
        XCTAssertEqual(r.topP, 0.95)
        XCTAssertEqual(r.maxTokens, 1024)
    }

    func testNilDefaultsLetsActiveWin() {
        let active = WorkspaceParamCascade(
            systemPrompt: "be terse",
            temperature: 0.2,
            topP: 0.9,
            maxTokens: 256
        )
        let r = WorkspaceParamCascade.resolve(active: active, defaults: nil)
        XCTAssertEqual(r.systemPrompt, "be terse")
        XCTAssertEqual(r.temperature, 0.2)
        XCTAssertEqual(r.topP, 0.9)
        XCTAssertEqual(r.maxTokens, 256)
    }

    func testActiveOverridesPerField() {
        let defaults = WorkspaceParamCascade(
            systemPrompt: "default prompt",
            temperature: 0.7,
            topP: 0.95,
            maxTokens: 1024
        )
        let active = WorkspaceParamCascade(
            systemPrompt: nil,                  // inherit default
            temperature: 0.1,                   // override
            topP: nil,                          // inherit default
            maxTokens: nil                      // inherit default
        )
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.systemPrompt, "default prompt", "nil active.systemPrompt must inherit from defaults")
        XCTAssertEqual(r.temperature, 0.1, "non-nil active.temperature wins")
        XCTAssertEqual(r.topP, 0.95)
        XCTAssertEqual(r.maxTokens, 1024)
    }

    func testActiveCanOverrideToEmptyString() {
        // A workspace explicitly setting systemPrompt to "" is a real
        // edit (user cleared the field) — it MUST override Default's
        // non-empty value, not be treated as nil-equivalent.
        let defaults = WorkspaceParamCascade(systemPrompt: "be helpful")
        let active = WorkspaceParamCascade(systemPrompt: "")
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.systemPrompt, "", "empty-string override is a real override, not equivalent to nil")
    }

    func testActiveCanOverrideToZero() {
        // Same shape: `temperature: 0.0` is a valid intent (greedy
        // sampling), distinct from "no override."
        let defaults = WorkspaceParamCascade(temperature: 0.7)
        let active = WorkspaceParamCascade(temperature: 0.0)
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.temperature, 0.0)
    }

    func testActiveSameAsDefaultsCollapsesIdempotently() {
        // The Default workspace passes the SAME row in both slots
        // (`active` and `defaults`). Result is just the row's values,
        // unchanged.
        let row = WorkspaceParamCascade(
            systemPrompt: "x",
            temperature: 0.5,
            topP: 0.9,
            maxTokens: 512
        )
        let r = WorkspaceParamCascade.resolve(active: row, defaults: row)
        XCTAssertEqual(r, row)
    }

    func testPartialDefaultsLeaveActiveWhereDefaultsAreNil() {
        let defaults = WorkspaceParamCascade(temperature: 0.7) // only temp
        let active = WorkspaceParamCascade(systemPrompt: "x", maxTokens: 256)
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.systemPrompt, "x")
        XCTAssertEqual(r.temperature, 0.7, "active.temperature was nil, falls to defaults")
        XCTAssertNil(r.topP, "neither active nor defaults set topP — stays nil")
        XCTAssertEqual(r.maxTokens, 256)
    }

    // MARK: - hasAnyOverride

    func testHasAnyOverrideReportsFalseForEmpty() {
        let empty = WorkspaceParamCascade()
        XCTAssertFalse(empty.hasAnyOverride)
    }

    func testHasAnyOverrideReportsTrueForAnySingleField() {
        XCTAssertTrue(WorkspaceParamCascade(systemPrompt: "x").hasAnyOverride)
        XCTAssertTrue(WorkspaceParamCascade(temperature: 0.1).hasAnyOverride)
        XCTAssertTrue(WorkspaceParamCascade(topP: 0.5).hasAnyOverride)
        XCTAssertTrue(WorkspaceParamCascade(maxTokens: 10).hasAnyOverride)
    }

    func testHasAnyOverrideEmptyStringStillCountsAsOverride() {
        // Symmetric with `testActiveCanOverrideToEmptyString`: an
        // empty string IS an override. The badge / clear-button UI
        // must surface it.
        XCTAssertTrue(WorkspaceParamCascade(systemPrompt: "").hasAnyOverride)
    }

    // MARK: - outputDirectory (Phase 2)

    func testOutputDirectoryFallsThroughToDefaults() {
        let defaults = WorkspaceParamCascade(outputDirectory: "~/Pictures/Infer/")
        let r = WorkspaceParamCascade.resolve(active: nil, defaults: defaults)
        XCTAssertEqual(r.outputDirectory, "~/Pictures/Infer/")
    }

    func testOutputDirectoryActiveOverridesDefault() {
        let defaults = WorkspaceParamCascade(outputDirectory: "/Users/x/Pictures/Default")
        let active = WorkspaceParamCascade(outputDirectory: "/Users/x/Pictures/Scratch")
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.outputDirectory, "/Users/x/Pictures/Scratch")
    }

    func testOutputDirectoryActivePartialFallsThroughForOtherFields() {
        // Active workspace overrides only outputDirectory; sampling
        // fields cascade from defaults. Confirms outputDirectory is
        // an independent axis in the cascade.
        let defaults = WorkspaceParamCascade(
            systemPrompt: "default",
            temperature: 0.7,
            outputDirectory: "/old/path"
        )
        let active = WorkspaceParamCascade(outputDirectory: "/new/path")
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.outputDirectory, "/new/path")
        XCTAssertEqual(r.systemPrompt, "default")
        XCTAssertEqual(r.temperature, 0.7)
    }

    func testOutputDirectoryEmptyStringIsAnOverride() {
        // Same shape as `testActiveCanOverrideToEmptyString`: an
        // explicit empty string is a real override (user cleared the
        // field), distinct from nil / "no override here." The
        // `setWorkspaceOutputDirectory` chat-VM helper trims and
        // normalises empty-to-nil before persistence so this case
        // shouldn't reach the store in practice — but the cascade
        // resolver itself must honour what it's given.
        let defaults = WorkspaceParamCascade(outputDirectory: "/has/path")
        let active = WorkspaceParamCascade(outputDirectory: "")
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.outputDirectory, "")
    }

    func testHasAnyOverrideIncludesOutputDirectory() {
        XCTAssertTrue(WorkspaceParamCascade(outputDirectory: "/x").hasAnyOverride)
        XCTAssertTrue(WorkspaceParamCascade(outputDirectory: "").hasAnyOverride)
    }

    // MARK: - activeAgentId (Phase 3)

    func testActiveAgentIdFallsThroughToDefaults() {
        let defaults = WorkspaceParamCascade(activeAgentId: "default-agent")
        let r = WorkspaceParamCascade.resolve(active: nil, defaults: defaults)
        XCTAssertEqual(r.activeAgentId, "default-agent")
    }

    func testActiveAgentIdActiveOverridesDefault() {
        let defaults = WorkspaceParamCascade(activeAgentId: "default")
        let active = WorkspaceParamCascade(activeAgentId: "code-helper")
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.activeAgentId, "code-helper")
    }

    func testActiveAgentIdIndependentFromOtherAxes() {
        // Active workspace pins an agent but inherits sampling +
        // outputDirectory from defaults. Confirms activeAgentId is
        // an independent cascade axis.
        let defaults = WorkspaceParamCascade(
            systemPrompt: "default sp",
            temperature: 0.7,
            outputDirectory: "/path/to/x",
            activeAgentId: "default-agent"
        )
        let active = WorkspaceParamCascade(activeAgentId: "researcher")
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.activeAgentId, "researcher")
        XCTAssertEqual(r.systemPrompt, "default sp")
        XCTAssertEqual(r.temperature, 0.7)
        XCTAssertEqual(r.outputDirectory, "/path/to/x")
    }

    func testActiveAgentIdEmptyStringIsAnOverride() {
        // Symmetric with the systemPrompt / outputDirectory cases:
        // empty string is a real override, distinct from nil.
        // The chat-VM's `recomposeActiveAgentFromActiveWorkspace`
        // guards on `rawId.isEmpty` and treats empty as no-op so
        // empty overrides don't reach the activation pipeline,
        // but the cascade resolver itself must honour what it's
        // given.
        let defaults = WorkspaceParamCascade(activeAgentId: "default")
        let active = WorkspaceParamCascade(activeAgentId: "")
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.activeAgentId, "")
    }

    func testHasAnyOverrideIncludesActiveAgentId() {
        XCTAssertTrue(WorkspaceParamCascade(activeAgentId: "x").hasAnyOverride)
        XCTAssertTrue(WorkspaceParamCascade(activeAgentId: "").hasAnyOverride)
    }

    // MARK: - enabledAgents (Phase 4a — set / allow-list cascade)

    func testEnabledAgentsFallsThroughToDefaults() {
        let defaults = WorkspaceParamCascade(enabledAgents: ["coder", "researcher"])
        let r = WorkspaceParamCascade.resolve(active: nil, defaults: defaults)
        XCTAssertEqual(r.enabledAgents, ["coder", "researcher"])
    }

    func testEnabledAgentsActiveOverridesDefault() {
        let defaults = WorkspaceParamCascade(enabledAgents: ["coder", "researcher"])
        let active = WorkspaceParamCascade(enabledAgents: ["editor"])
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.enabledAgents, ["editor"])
    }

    func testEnabledAgentsEmptyArrayIsExplicitSilence() {
        // The set-axis analogue of empty-string-is-an-override: an
        // explicit `[]` means "this workspace silences every agent
        // (except the safety net the consumer adds). Distinct from
        // nil (which falls through). The cascade resolver must
        // honour the empty array as the override; the
        // DefaultAgent safety net is the consumer's job
        // (`ChatViewModel.effectiveEnabledAgents`).
        let defaults = WorkspaceParamCascade(enabledAgents: ["coder", "researcher"])
        let active = WorkspaceParamCascade(enabledAgents: [])
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.enabledAgents, [], "empty active list must override defaults, not fall through")
    }

    func testEnabledAgentsBothLayersNilProducesNil() {
        // `nil` at both layers means "no allow-list active anywhere"
        // — the consumer reads this as "everything available."
        // Distinct from the empty-array case above.
        let r = WorkspaceParamCascade.resolve(active: nil, defaults: nil)
        XCTAssertNil(r.enabledAgents)
    }

    func testEnabledAgentsIndependentFromOtherAxes() {
        // Active workspace pins an allow-list but inherits sampling +
        // outputDirectory from defaults.
        let defaults = WorkspaceParamCascade(
            systemPrompt: "default",
            temperature: 0.7,
            outputDirectory: "/path",
            activeAgentId: "default-agent",
            enabledAgents: ["a", "b"]
        )
        let active = WorkspaceParamCascade(enabledAgents: ["c"])
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.enabledAgents, ["c"])
        XCTAssertEqual(r.systemPrompt, "default")
        XCTAssertEqual(r.temperature, 0.7)
        XCTAssertEqual(r.outputDirectory, "/path")
        XCTAssertEqual(r.activeAgentId, "default-agent")
    }

    func testHasAnyOverrideIncludesEnabledAgents() {
        XCTAssertTrue(WorkspaceParamCascade(enabledAgents: ["x"]).hasAnyOverride)
        XCTAssertTrue(WorkspaceParamCascade(enabledAgents: []).hasAnyOverride,
                      "explicit empty list IS an override (workspace-silenced state)")
    }

    func testEnabledAgentsResolverDoesNotInjectSafetyNet() {
        // The DefaultAgent-always-allowed safety net is enforced at
        // the consumer (`ChatViewModel.effectiveEnabledAgents`), NOT
        // here. The cascade resolver returns the list as stored, so
        // an empty array stays empty after `resolve`. This contract
        // matters because moving the safety net into the resolver
        // would couple `InferAppCore` to the chat-VM's notion of a
        // "default agent" (which lives in `InferAgents`); keeping it
        // out preserves the dependency graph.
        let active = WorkspaceParamCascade(enabledAgents: [])
        let r = WorkspaceParamCascade.resolve(active: active, defaults: nil)
        XCTAssertEqual(r.enabledAgents, [],
                       "resolver returns the list as stored; safety net is the consumer's job")
    }

    // MARK: - enabledTools (Phase 4b — set / allow-list cascade, no safety net)

    func testEnabledToolsFallsThroughToDefaults() {
        let defaults = WorkspaceParamCascade(enabledTools: ["http.fetch", "fs.read"])
        let r = WorkspaceParamCascade.resolve(active: nil, defaults: defaults)
        XCTAssertEqual(r.enabledTools, ["http.fetch", "fs.read"])
    }

    func testEnabledToolsActiveOverridesDefault() {
        let defaults = WorkspaceParamCascade(enabledTools: ["http.fetch"])
        let active = WorkspaceParamCascade(enabledTools: ["fs.read"])
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.enabledTools, ["fs.read"])
    }

    func testEnabledToolsEmptyArrayReallyMeansNoTools() {
        // Unlike enabledAgents (which has a DefaultAgent safety net
        // at the chat-VM consumer), an empty tools allow-list is
        // semantically "no tools available" — that's a legitimate
        // workspace shape (security-sensitive contexts). The
        // resolver returns the empty array; the consumer
        // (`ChatViewModel.effectiveEnabledTools`) returns
        // `Set<String>()` — distinct from `nil`.
        let defaults = WorkspaceParamCascade(enabledTools: ["http.fetch"])
        let active = WorkspaceParamCascade(enabledTools: [])
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.enabledTools, [], "empty tools list overrides defaults — workspace-silenced state")
    }

    func testEnabledToolsBothLayersNilProducesNil() {
        let r = WorkspaceParamCascade.resolve(active: nil, defaults: nil)
        XCTAssertNil(r.enabledTools)
    }

    func testEnabledToolsIndependentFromEnabledAgents() {
        // Both set-axis fields can be present at different cascade
        // layers and resolve independently. Catches a class of bug
        // where a refactor accidentally couples the two through a
        // shared resolver path.
        let defaults = WorkspaceParamCascade(
            enabledAgents: ["coder"],
            enabledTools: ["http.fetch"]
        )
        let active = WorkspaceParamCascade(enabledTools: ["fs.read"])
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.enabledAgents, ["coder"], "agents allow-list inherits from defaults")
        XCTAssertEqual(r.enabledTools, ["fs.read"], "tools allow-list overridden by active")
    }

    func testHasAnyOverrideIncludesEnabledTools() {
        XCTAssertTrue(WorkspaceParamCascade(enabledTools: ["x"]).hasAnyOverride)
        XCTAssertTrue(WorkspaceParamCascade(enabledTools: []).hasAnyOverride,
                      "explicit empty tools list IS an override (workspace-silenced state)")
    }

    // MARK: - enabledMCPServers (Phase 4c — set / allow-list cascade)

    func testEnabledMCPServersFallsThroughToDefaults() {
        let defaults = WorkspaceParamCascade(enabledMCPServers: ["filesystem", "github"])
        let r = WorkspaceParamCascade.resolve(active: nil, defaults: defaults)
        XCTAssertEqual(r.enabledMCPServers, ["filesystem", "github"])
    }

    func testEnabledMCPServersActiveOverridesDefault() {
        let defaults = WorkspaceParamCascade(enabledMCPServers: ["filesystem"])
        let active = WorkspaceParamCascade(enabledMCPServers: ["github"])
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.enabledMCPServers, ["github"])
    }

    func testEnabledMCPServersEmptyArrayIsExplicitSilence() {
        // Same set-axis semantics as enabledTools: empty list is the
        // workspace-silenced state, distinct from nil. The consumer
        // (`ChatViewModel.effectiveEnabledTools`) subtracts every
        // `mcp.*` tool when this resolves to an empty set.
        let defaults = WorkspaceParamCascade(enabledMCPServers: ["filesystem"])
        let active = WorkspaceParamCascade(enabledMCPServers: [])
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.enabledMCPServers, [], "empty MCP servers list overrides defaults")
    }

    func testEnabledMCPServersIndependentFromEnabledTools() {
        // The two set-axis fields resolve independently in the
        // cascade. Composition (subtracting MCP-derived tools when
        // their server is allow-listed out) happens in the chat-VM
        // consumer, not in the resolver — verified by
        // `testEnabledMCPServersResolverIsPurePassthrough` below
        // and by the chat-VM-side composition tests separately.
        let defaults = WorkspaceParamCascade(
            enabledTools: ["http.fetch"],
            enabledMCPServers: ["filesystem"]
        )
        let active = WorkspaceParamCascade(enabledMCPServers: ["github"])
        let r = WorkspaceParamCascade.resolve(active: active, defaults: defaults)
        XCTAssertEqual(r.enabledTools, ["http.fetch"], "tools list inherits from defaults")
        XCTAssertEqual(r.enabledMCPServers, ["github"], "MCP servers list overridden by active")
    }

    func testHasAnyOverrideIncludesEnabledMCPServers() {
        XCTAssertTrue(WorkspaceParamCascade(enabledMCPServers: ["x"]).hasAnyOverride)
        XCTAssertTrue(WorkspaceParamCascade(enabledMCPServers: []).hasAnyOverride,
                      "explicit empty MCP servers list IS an override")
    }

    func testEnabledMCPServersResolverIsPurePassthrough() {
        // Mirror of the Phase 4a `testEnabledAgentsResolverDoesNotInjectSafetyNet`
        // contract: the resolver does no composition with other axes.
        // The consumer composes Phase 4b + Phase 4c (subtracting
        // tools whose server is disallowed). Decoupling that
        // composition from the resolver keeps `InferAppCore`
        // independent of MCP tool-naming conventions (which live in
        // `InferAgents` via `MCPBuiltinTool.init`).
        let active = WorkspaceParamCascade(
            enabledTools: ["mcp.filesystem.read", "mcp.github.search"],
            enabledMCPServers: ["github"]
        )
        let r = WorkspaceParamCascade.resolve(active: active, defaults: nil)
        XCTAssertEqual(r.enabledTools, ["mcp.filesystem.read", "mcp.github.search"],
                       "resolver returns the tools list as stored — composition is the consumer's job")
        XCTAssertEqual(r.enabledMCPServers, ["github"])
    }
}
