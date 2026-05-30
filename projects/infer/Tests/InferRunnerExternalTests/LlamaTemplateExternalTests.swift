import XCTest
@testable import Infer

/// Exercises the real LlamaCpp Jinja chat-format bridge
/// (`chatfmt_apply` in `libchatfmt.dylib`, shipped inside
/// `LlamaCpp.framework`) through `LlamaRunner.renderTemplate`. This is
/// the only coverage of the template-rendering path introduced by the
/// GGUF-Jinja change — `renderTemplate` is not pure (it calls into the
/// framework), so the suite carries the `*ExternalTests` suffix: `make
/// test` skips it (`--skip ExternalTests`), `make test-integration`
/// runs it (`--filter ExternalTests`).
///
/// What these pin that nothing else does:
/// - role iteration + content interpolation actually reach the model's
///   template (a regression in the JSON marshalling or the bridge call
///   would drop them),
/// - `add_generation_prompt` is wired from the `addAssistant` flag (the
///   delta between "format the history" and "format + open an assistant
///   turn" that the decode loop depends on),
/// - `bos_token` / `eos_token` are bound from the runner's snapshotted
///   special tokens,
/// - an empty / nil template is rejected rather than silently producing
///   a degenerate prompt.
///
/// Opt-out: set `INFER_SKIP_LLAMA_EXTERNAL=1` to skip even when the
/// framework is linked (fast local iteration without `make test`).
final class LlamaTemplateExternalTests: XCTestCase {

    private static let skipEnvKey = "INFER_SKIP_LLAMA_EXTERNAL"

    private func skipIfOptedOut() throws {
        if ProcessInfo.processInfo.environment[Self.skipEnvKey] == "1" {
            throw XCTSkip("\(Self.skipEnvKey)=1")
        }
    }

    /// Minimal but complete template: wrap each message in role tags,
    /// and append an assistant opener only when `add_generation_prompt`
    /// is set. Enough to assert the bridge iterates, interpolates, and
    /// honours the generation-prompt flag.
    private let minimalTemplate = """
    {% for message in messages %}<|{{ message['role'] }}|>
    {{ message['content'] }}
    {% endfor %}{% if add_generation_prompt %}<|assistant|>
    {% endif %}
    """

    func testRendersRolesAndContent() throws {
        try skipIfOptedOut()
        let out = try LlamaRunner.renderTemplate(
            template: minimalTemplate,
            bosToken: nil,
            eosToken: nil,
            messages: [
                (role: "system", content: "Be terse."),
                (role: "user", content: "Hi"),
            ],
            addAssistant: false
        )
        XCTAssertTrue(out.contains("<|system|>"), out)
        XCTAssertTrue(out.contains("Be terse."), out)
        XCTAssertTrue(out.contains("<|user|>"), out)
        XCTAssertTrue(out.contains("Hi"), out)
        // No assistant opener when addAssistant is false.
        XCTAssertFalse(out.contains("<|assistant|>"), out)
    }

    func testAddAssistantAppendsGenerationPrompt() throws {
        try skipIfOptedOut()
        let messages = [(role: "user", content: "Hi")]
        let base = try LlamaRunner.renderTemplate(
            template: minimalTemplate, bosToken: nil, eosToken: nil,
            messages: messages, addAssistant: false
        )
        let withAss = try LlamaRunner.renderTemplate(
            template: minimalTemplate, bosToken: nil, eosToken: nil,
            messages: messages, addAssistant: true
        )
        XCTAssertFalse(base.contains("<|assistant|>"), base)
        XCTAssertTrue(withAss.contains("<|assistant|>"), withAss)
        // The add-assistant render is the no-assistant render plus the
        // opener — i.e. the history prefix is stable across the flag.
        XCTAssertTrue(withAss.hasPrefix(base), "expected withAss to extend base\nbase=\(base)\nwithAss=\(withAss)")
    }

    func testBosEosTokenInterpolation() throws {
        try skipIfOptedOut()
        let tmpl = "{{ bos_token }}{% for m in messages %}{{ m['content'] }}{{ eos_token }}{% endfor %}"
        let out = try LlamaRunner.renderTemplate(
            template: tmpl, bosToken: "<BOS>", eosToken: "<EOS>",
            messages: [(role: "user", content: "x")], addAssistant: false
        )
        XCTAssertTrue(out.hasPrefix("<BOS>"), out)
        XCTAssertTrue(out.contains("<EOS>"), out)
    }

    func testLlama3StyleTemplateMarkers() throws {
        try skipIfOptedOut()
        let tmpl = """
        {% for message in messages %}<|start_header_id|>{{ message['role'] }}<|end_header_id|>

        {{ message['content'] }}<|eot_id|>{% endfor %}{% if add_generation_prompt %}<|start_header_id|>assistant<|end_header_id|>

        {% endif %}
        """
        let out = try LlamaRunner.renderTemplate(
            template: tmpl, bosToken: "<|begin_of_text|>", eosToken: nil,
            messages: [
                (role: "system", content: "S"),
                (role: "user", content: "U"),
            ],
            addAssistant: true
        )
        XCTAssertTrue(out.contains("<|start_header_id|>system<|end_header_id|>"), out)
        XCTAssertTrue(out.contains("<|start_header_id|>user<|end_header_id|>"), out)
        XCTAssertTrue(out.contains("<|eot_id|>"), out)
        // add_generation_prompt opened an assistant header.
        XCTAssertTrue(out.contains("<|start_header_id|>assistant<|end_header_id|>"), out)
    }

    func testEmptyTemplateThrows() throws {
        try skipIfOptedOut()
        XCTAssertThrowsError(try LlamaRunner.renderTemplate(
            template: "", bosToken: nil, eosToken: nil,
            messages: [(role: "user", content: "x")], addAssistant: false
        )) { error in
            guard case LlamaError.templateFailed = error else {
                return XCTFail("expected templateFailed, got \(error)")
            }
        }
    }

    func testNilTemplateThrows() throws {
        try skipIfOptedOut()
        XCTAssertThrowsError(try LlamaRunner.renderTemplate(
            template: nil, bosToken: nil, eosToken: nil,
            messages: [], addAssistant: false
        )) { error in
            guard case LlamaError.templateFailed = error else {
                return XCTFail("expected templateFailed, got \(error)")
            }
        }
    }
}
