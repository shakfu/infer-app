import XCTest
@testable import InferAgents
@testable import InferCore

/// Unit tests for `AutoAgent`'s static helpers — the picker integration
/// itself is exercised end-to-end by the chat VM (see
/// `Generation.swift`'s Auto special-case) and indirectly by the
/// `.react` driver tests in `CompositionAdvancedTests`.
final class AutoAgentTests: XCTestCase {

    // MARK: - candidateIds

    func testCandidateIdsExcludesAutoAndDefault() {
        let listings: [AgentListing] = [
            Self.makeListing(id: "infer.default", isDefault: true),
            Self.makeListing(id: AutoAgent.id),
            Self.makeListing(id: "user.coder"),
            Self.makeListing(id: "user.writer"),
        ]
        let result = AutoAgent.candidateIds(from: listings) { _ in true }
        XCTAssertEqual(result.map(\.id), ["user.coder", "user.writer"])
    }

    func testCandidateIdsHonoursCompatibilityFilter() {
        let listings: [AgentListing] = [
            Self.makeListing(id: "user.coder"),
            Self.makeListing(id: "user.writer"),
            Self.makeListing(id: "user.imager"),
        ]
        let result = AutoAgent.candidateIds(from: listings) { listing in
            listing.id != "user.imager"
        }
        XCTAssertEqual(result.map(\.id), ["user.coder", "user.writer"])
    }

    func testCandidateIdsEmptyWhenNothingCompatible() {
        let listings: [AgentListing] = [
            Self.makeListing(id: "infer.default", isDefault: true),
            Self.makeListing(id: AutoAgent.id),
        ]
        let result = AutoAgent.candidateIds(from: listings) { _ in true }
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - renderCandidateListing

    func testRenderCandidateListingFormatsIdNameDescription() {
        let listings: [AgentListing] = [
            Self.makeListing(id: "user.coder", name: "Coder", description: "Writes code."),
            Self.makeListing(id: "user.writer", name: "Writer", description: "Writes prose."),
        ]
        let out = AutoAgent.renderCandidateListing(listings)
        XCTAssertTrue(out.contains("# Available agents"))
        XCTAssertTrue(out.contains("- `user.coder` — Coder: Writes code."))
        XCTAssertTrue(out.contains("- `user.writer` — Writer: Writes prose."))
    }

    func testRenderCandidateListingHandlesEmptyDescription() {
        let listings: [AgentListing] = [
            Self.makeListing(id: "user.coder", name: "Coder", description: ""),
        ]
        let out = AutoAgent.renderCandidateListing(listings)
        XCTAssertTrue(out.contains("- `user.coder` — Coder"))
        // No trailing colon when description is empty.
        XCTAssertFalse(out.contains("Coder: "))
    }

    func testRenderCandidateListingEmptyForEmptyInput() {
        XCTAssertEqual(AutoAgent.renderCandidateListing([]), "")
    }

    // MARK: - renderRouterInput

    func testRenderRouterInputPrependsListingAndUserSection() {
        let listings: [AgentListing] = [
            Self.makeListing(id: "user.coder", name: "Coder", description: "Writes code."),
        ]
        let out = AutoAgent.renderRouterInput(
            userText: "review this PR",
            candidates: listings
        )
        XCTAssertTrue(out.contains("# Available agents"))
        XCTAssertTrue(out.contains("# User request"))
        XCTAssertTrue(out.contains("review this PR"))
        // Listing precedes the user request so the model reads
        // candidates first and decides before parsing the request.
        let listingLoc = out.range(of: "# Available agents")!.lowerBound
        let userLoc = out.range(of: "# User request")!.lowerBound
        XCTAssertLessThan(listingLoc, userLoc)
    }

    func testRenderRouterInputDegradesToBareTextWhenNoCandidates() {
        let out = AutoAgent.renderRouterInput(userText: "hello", candidates: [])
        XCTAssertEqual(out, "hello")
    }

    // MARK: - systemPrompt

    func testSystemPromptIncludesRoutingProtocol() async throws {
        let agent = AutoAgent(settings: .defaults)
        let ctx = AgentContext(
            runner: RunnerHandle(backend: .llama, templateFamily: nil, maxContext: 0, currentTokenCount: 0),
            tools: ToolCatalog(tools: []),
            retrieve: { _, _ in [] }
        )
        let prompt = try await agent.systemPrompt(for: ctx)
        XCTAssertTrue(prompt.contains("agents.invoke"))
        XCTAssertTrue(prompt.contains("# Available agents"))
        XCTAssertTrue(prompt.contains("# User request"))
    }

    // MARK: - requirements

    func testRequirementsAllowsAgentsInvokeOnly() {
        let req = AutoAgent(settings: .defaults).requirements
        XCTAssertEqual(req.toolsAllow, ["agents.invoke"])
        XCTAssertEqual(req.backend, .any)
    }

    // MARK: - Helpers

    private static func makeListing(
        id: AgentID,
        name: String? = nil,
        description: String = "",
        isDefault: Bool = false
    ) -> AgentListing {
        AgentListing(
            id: id,
            name: name ?? id.rawValue,
            description: description,
            source: .firstParty,
            backend: .any,
            templateFamily: nil,
            kind: .agent,
            isDefault: isDefault
        )
    }
}
