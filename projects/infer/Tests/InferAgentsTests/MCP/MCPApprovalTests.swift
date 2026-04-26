import XCTest
@testable import InferAgents

final class MCPApprovalTests: XCTestCase {

    private func ephemeralDefaults() -> UserDefaults {
        // Per-test domain so tests don't pollute each other or the
        // shipping `standard` domain.
        let suite = "mcp.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - MCPApprovalStore

    func testApproveAndIsApprovedRoundTrip() {
        let defaults = ephemeralDefaults()
        let store = MCPApprovalStore(defaults: defaults)
        XCTAssertFalse(store.isApproved(serverID: "fs"))
        store.approve(serverID: "fs")
        XCTAssertTrue(store.isApproved(serverID: "fs"))
    }

    func testRevokeRemovesApproval() {
        let defaults = ephemeralDefaults()
        let store = MCPApprovalStore(defaults: defaults)
        store.approve(serverID: "fs")
        store.approve(serverID: "slack")
        store.revoke(serverID: "fs")
        XCTAssertFalse(store.isApproved(serverID: "fs"))
        XCTAssertTrue(store.isApproved(serverID: "slack"))
    }

    func testApprovedServersIsDeterministicallyOrderedOnDisk() {
        let defaults = ephemeralDefaults()
        let store = MCPApprovalStore(defaults: defaults)
        store.approve(serverID: "z")
        store.approve(serverID: "a")
        store.approve(serverID: "m")
        // The on-disk array is sorted (helps a user peeking at the
        // plist see a stable order).
        let stored = defaults.array(forKey: MCPApprovalStore.defaultsKey) as? [String]
        XCTAssertEqual(stored, ["a", "m", "z"])
    }

    // MARK: - defaultMCPApprovalProvider

    func testDefaultProviderDeniesUnknown() async {
        let defaults = ephemeralDefaults()
        let provider = defaultMCPApprovalProvider(
            store: MCPApprovalStore(defaults: defaults)
        )
        let cfg = MCPServerConfig(id: "unknown", command: "x")
        let decision = await provider(cfg)
        XCTAssertEqual(decision, .deny)
    }

    func testDefaultProviderAllowsApproved() async {
        let defaults = ephemeralDefaults()
        let store = MCPApprovalStore(defaults: defaults)
        store.approve(serverID: "fs")
        let provider = defaultMCPApprovalProvider(store: store)
        let cfg = MCPServerConfig(id: "fs", command: "x")
        let decision = await provider(cfg)
        XCTAssertEqual(decision, .allowOnce)
    }

    func testAutoApproveBypassesStore() async {
        let defaults = ephemeralDefaults()
        let provider = defaultMCPApprovalProvider(
            store: MCPApprovalStore(defaults: defaults)
        )
        let cfg = MCPServerConfig(
            id: "trusted",
            command: "x",
            autoApprove: true
        )
        let decision = await provider(cfg)
        XCTAssertEqual(decision, .allowOnce, "autoApprove short-circuits the store check")
    }

    // MARK: - Config

    func testServerConfigDecodesAutoApproveAndRoots() throws {
        let json = #"""
        {
          "id":"fs",
          "command":"/usr/local/bin/fs-mcp",
          "autoApprove":true,
          "roots":["~/Documents","/tmp/work"]
        }
        """#
        let cfg = try JSONDecoder().decode(MCPServerConfig.self, from: Data(json.utf8))
        XCTAssertTrue(cfg.autoApprove)
        XCTAssertEqual(cfg.roots, ["~/Documents", "/tmp/work"])
    }

    func testServerConfigDefaultsForNewFields() throws {
        // Pre-existing minimal configs (no autoApprove / roots keys)
        // must keep working with safe defaults.
        let json = #"{"id":"x","command":"/bin/true"}"#
        let cfg = try JSONDecoder().decode(MCPServerConfig.self, from: Data(json.utf8))
        XCTAssertFalse(cfg.autoApprove)
        XCTAssertEqual(cfg.roots, [])
    }
}
