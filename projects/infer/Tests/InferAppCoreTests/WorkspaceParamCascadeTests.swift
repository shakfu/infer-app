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
}
