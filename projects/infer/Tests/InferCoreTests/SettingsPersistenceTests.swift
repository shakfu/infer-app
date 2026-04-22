import XCTest
@testable import InferCore

final class SettingsPersistenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "infer.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEmptyDefaultsReturnsDefaults() {
        XCTAssertEqual(InferSettings.load(from: defaults), .defaults)
    }

    func testRoundTripAllFields() {
        let original = InferSettings(
            systemPrompt: "you are a helpful assistant",
            temperature: 0.42,
            topP: 0.77,
            maxTokens: 2048
        )
        original.save(to: defaults)
        XCTAssertEqual(InferSettings.load(from: defaults), original)
    }

    func testPartialPersistFallsBackToDefaultsPerField() {
        defaults.set(0.25, forKey: PersistKey.temperature)
        let loaded = InferSettings.load(from: defaults)
        XCTAssertEqual(loaded.temperature, 0.25)
        XCTAssertEqual(loaded.systemPrompt, InferSettings.defaults.systemPrompt)
        XCTAssertEqual(loaded.topP, InferSettings.defaults.topP)
        XCTAssertEqual(loaded.maxTokens, InferSettings.defaults.maxTokens)
    }

    func testSaveOverwritesPreviousValues() {
        InferSettings(systemPrompt: "a", temperature: 0.1, topP: 0.2, maxTokens: 10).save(to: defaults)
        InferSettings(systemPrompt: "b", temperature: 0.9, topP: 0.8, maxTokens: 999).save(to: defaults)
        let loaded = InferSettings.load(from: defaults)
        XCTAssertEqual(loaded.systemPrompt, "b")
        XCTAssertEqual(loaded.temperature, 0.9)
        XCTAssertEqual(loaded.topP, 0.8)
        XCTAssertEqual(loaded.maxTokens, 999)
    }

    func testMalformedValueTypeFallsBackToDefault() {
        // A previous version of the app (or a manual plist edit) might have
        // written a string where a Double is expected. `load` should not
        // crash and should fall back to the default for that field.
        defaults.set("not-a-number", forKey: PersistKey.temperature)
        XCTAssertEqual(InferSettings.load(from: defaults).temperature, InferSettings.defaults.temperature)
    }
}
