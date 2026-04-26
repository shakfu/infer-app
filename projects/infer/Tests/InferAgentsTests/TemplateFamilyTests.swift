import XCTest
@testable import InferAgents
@testable import InferCore

/// M4 (`docs/dev/agent_implementation_plan.md`): runner-side template
/// fingerprinting feeds the agent layer's compatibility check so a
/// Qwen-template agent on a Llama 3 GGUF (or vice versa) fails loud
/// in the picker rather than silently emitting the wrong tool tags.
final class TemplateFamilyTests: XCTestCase {

    // MARK: - fingerprint heuristic

    func testFingerprintLlama3PythonTag() {
        let template = """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>
        ...
        Tool: <|python_tag|>{"name": "x", "parameters": {}}<|eom_id|>
        """
        XCTAssertEqual(TemplateFamily.fingerprint(template: template), .llama3)
    }

    func testFingerprintLlama3HeaderTokensWithoutPythonTag() {
        let template = "<|start_header_id|>user<|end_header_id|>hello<|eot_id|>"
        XCTAssertEqual(TemplateFamily.fingerprint(template: template), .llama3)
    }

    func testFingerprintQwenChatMLWithToolCall() {
        let template = """
        <|im_start|>system
        You are a tool-using assistant. Wrap calls in <tool_call>...</tool_call>.
        <|im_end|>
        """
        XCTAssertEqual(TemplateFamily.fingerprint(template: template), .qwen)
    }

    func testFingerprintChatMLWithoutToolCallReturnsNil() {
        // ChatML alone — model can chat, but tool-syntax is unspecified.
        // Conservative: surface as nil so the picker fails loud rather
        // than guessing.
        let template = "<|im_start|>system\nYou are helpful.<|im_end|>"
        XCTAssertNil(TemplateFamily.fingerprint(template: template))
    }

    func testFingerprintEmptyAndNilReturnNil() {
        XCTAssertNil(TemplateFamily.fingerprint(template: nil))
        XCTAssertNil(TemplateFamily.fingerprint(template: ""))
    }

    func testFingerprintUnknownTemplateReturnsNil() {
        let template = "Some random text with no recognisable markers."
        XCTAssertNil(TemplateFamily.fingerprint(template: template))
    }

    // MARK: - AgentController compatibility on template mismatch

    @MainActor
    func testCompatibilityFailsOnTemplateFamilyMismatch() async {
        let controller = AgentController(registry: AgentRegistry())
        await controller.bootstrap(settings: .defaults, personasDirectory: nil)

        let listing = AgentListing(
            id: "qwen.tool.agent",
            name: "Qwen tool agent",
            description: "",
            source: .firstParty,
            backend: .llama,
            templateFamily: .qwen,
            kind: .agent,
            isDefault: false
        )

        // Detected llama3 — Qwen agent must fail loud.
        controller.setDetectedTemplateFamily(.llama3)
        XCTAssertFalse(controller.isCompatible(listing, backend: .llama))
        XCTAssertTrue(
            controller.incompatibilityReason(listing, backend: .llama).contains("qwen"),
            "expected reason to mention required family, got: \(controller.incompatibilityReason(listing, backend: .llama))"
        )
    }

    @MainActor
    func testCompatibilityPassesWhenTemplateMatches() async {
        let controller = AgentController(registry: AgentRegistry())
        await controller.bootstrap(settings: .defaults, personasDirectory: nil)

        let listing = AgentListing(
            id: "llama.tool.agent",
            name: "Llama tool agent",
            description: "",
            source: .firstParty,
            backend: .llama,
            templateFamily: .llama3,
            kind: .agent,
            isDefault: false
        )

        controller.setDetectedTemplateFamily(.llama3)
        XCTAssertTrue(controller.isCompatible(listing, backend: .llama))
        XCTAssertEqual(controller.incompatibilityReason(listing, backend: .llama), "")
    }

    @MainActor
    func testCompatibilityFailsWhenTemplateRequiredButNoneDetected() async {
        let controller = AgentController(registry: AgentRegistry())
        await controller.bootstrap(settings: .defaults, personasDirectory: nil)

        let listing = AgentListing(
            id: "llama.tool.agent",
            name: "Llama tool agent",
            description: "",
            source: .firstParty,
            backend: .llama,
            templateFamily: .llama3,
            kind: .agent,
            isDefault: false
        )

        // No detection (e.g. no model loaded yet). A tool agent that
        // demands a specific family must fail loud.
        controller.setDetectedTemplateFamily(nil)
        XCTAssertFalse(controller.isCompatible(listing, backend: .llama))
        XCTAssertTrue(
            controller.incompatibilityReason(listing, backend: .llama).contains("none detected"),
            "got: \(controller.incompatibilityReason(listing, backend: .llama))"
        )
    }

    @MainActor
    func testCompatibilityIgnoredWhenAgentDeclaresNoFamily() async {
        let controller = AgentController(registry: AgentRegistry())
        await controller.bootstrap(settings: .defaults, personasDirectory: nil)

        let listing = AgentListing(
            id: "any.persona",
            name: "Any persona",
            description: "",
            source: .firstParty,
            backend: .any,
            templateFamily: nil,
            kind: .persona,
            isDefault: false
        )

        // Mismatched detection should not gate an agent that doesn't
        // care — most personas live in this bucket.
        controller.setDetectedTemplateFamily(.qwen)
        XCTAssertTrue(controller.isCompatible(listing, backend: .llama))
    }

    @MainActor
    func testBackendIncompatibilityWinsOverTemplateMessage() async {
        let controller = AgentController(registry: AgentRegistry())
        await controller.bootstrap(settings: .defaults, personasDirectory: nil)

        let listing = AgentListing(
            id: "mlx-only",
            name: "MLX-only",
            description: "",
            source: .firstParty,
            backend: .mlx,
            templateFamily: .qwen,
            kind: .agent,
            isDefault: false
        )

        // Two reasons to be incompatible (wrong backend, wrong template).
        // The reason surfaced is the backend one — the user can't fix
        // template before fixing backend.
        controller.setDetectedTemplateFamily(.llama3)
        XCTAssertFalse(controller.isCompatible(listing, backend: .llama))
        XCTAssertEqual(
            controller.incompatibilityReason(listing, backend: .llama),
            "Requires MLX backend"
        )
    }

    // MARK: - composeSystemPrompt dispatches

    @MainActor
    func testComposeSystemPromptLlama3UsesPythonTag() {
        let prompt = AgentController.composeSystemPrompt(
            base: "You are helpful.",
            tools: [ToolSpec(name: "builtin.clock.now", description: "now")],
            family: .llama3
        )
        XCTAssertTrue(prompt.contains("<|python_tag|>"))
        XCTAssertTrue(prompt.contains("<|eom_id|>"))
        XCTAssertFalse(prompt.contains("<tool_call>"))
    }

    @MainActor
    func testComposeSystemPromptQwenUsesToolCallTag() {
        let prompt = AgentController.composeSystemPrompt(
            base: "You are helpful.",
            tools: [ToolSpec(name: "builtin.clock.now", description: "now")],
            family: .qwen
        )
        XCTAssertTrue(prompt.contains("<tool_call>"))
        XCTAssertTrue(prompt.contains("</tool_call>"))
        XCTAssertFalse(prompt.contains("<|python_tag|>"))
    }

    @MainActor
    func testComposeSystemPromptEmptyToolsReturnsBaseUnchanged() {
        let prompt = AgentController.composeSystemPrompt(
            base: "Plain persona.",
            tools: [],
            family: .qwen
        )
        XCTAssertEqual(prompt, "Plain persona.")
    }
}
