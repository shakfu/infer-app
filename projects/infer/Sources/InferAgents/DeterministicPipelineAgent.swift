import Foundation

/// An `Agent` conformance that runs a fixed sequence of tool calls
/// with no LLM decoding.
///
/// Use cases this serves:
///
/// - *External-API agents.* "Fetch this URL, parse the JSON,
///   surface a specific field."
/// - *Pre-processors.* "Run vault.search, format the chunks into a
///   compact bullet list, hand the result to the next agent in the
///   chain." The next agent (LLM-backed) sees clean structured input
///   instead of raw retrieval output.
/// - *Adapters.* "Dispatch to an external service, normalise the
///   shape of its response, hand off to a domain expert."
///
/// Each `Step` describes one tool call:
/// - `name`: which tool from the `ToolCatalog` to invoke.
/// - `arguments`: a closure that builds the JSON-encoded argument
///   string from the user's input plus the bag of named outputs the
///   pipeline has accumulated so far.
/// - `bind`: a name to store this step's `ToolResult.output` under,
///   so subsequent steps can reference it. `nil` discards the output.
///
/// The pipeline's final answer is built by `output`, which composes
/// the named outputs into a single string. Common patterns:
/// - `output: { _, bag in bag["last_step"] ?? "" }` — pass the last
///   step through unchanged.
/// - `output: { user, bag in "Source: \(user)\n\n\(bag["fetched"]!)" }` —
///   prepend the user query to the fetched data for the downstream
///   agent.
///
/// On any tool error (the invoker throws, or the result carries a
/// non-nil `error`), the pipeline emits the error step and stops.
/// Subsequent steps are skipped — pipelines are short and
/// fail-loud is the right default.
public struct DeterministicPipelineAgent: Agent {
    public typealias ArgumentBuilder = @Sendable (
        _ userText: String,
        _ outputs: [String: String]
    ) throws -> String

    public typealias OutputBuilder = @Sendable (
        _ userText: String,
        _ outputs: [String: String]
    ) -> String

    public struct Step: Sendable {
        public let name: ToolName
        public let arguments: ArgumentBuilder
        public let bind: String?

        public init(
            name: ToolName,
            arguments: @escaping ArgumentBuilder,
            bind: String? = nil
        ) {
            self.name = name
            self.arguments = arguments
            self.bind = bind
        }

        /// Convenience: a step whose arguments are a fixed JSON string.
        /// Useful for tools that ignore the user input (e.g. a clock
        /// tool always called with `{}`).
        public static func fixed(
            name: ToolName,
            arguments: String,
            bind: String? = nil
        ) -> Step {
            Step(name: name, arguments: { _, _ in arguments }, bind: bind)
        }
    }

    public let id: AgentID
    public let metadata: AgentMetadata
    public let requirements: AgentRequirements
    public let steps: [Step]
    public let output: OutputBuilder
    public let defaultDecodingParams: DecodingParams

    public init(
        id: AgentID,
        metadata: AgentMetadata,
        toolsAllow: [ToolName],
        steps: [Step],
        output: @escaping OutputBuilder,
        decodingParams: DecodingParams = DecodingParams(
            temperature: 0, topP: 1, maxTokens: 0
        )
    ) {
        self.id = id
        self.metadata = metadata
        // Tools are invoked directly via `context.invokeTool`, but
        // surfacing them through `requirements.toolsAllow` keeps the
        // host's per-agent tool gating consistent: the picker still
        // lists which tools the agent reaches, and the catalog
        // intersection in the default `toolsAvailable` hook still
        // filters appropriately.
        self.requirements = AgentRequirements(
            backend: .any,
            templateFamily: nil,
            toolsAllow: toolsAllow
        )
        self.steps = steps
        self.output = output
        self.defaultDecodingParams = decodingParams
    }

    public func decodingParams(for context: AgentContext) -> DecodingParams {
        defaultDecodingParams
    }

    /// No system prompt: deterministic pipelines never reach the LLM,
    /// so there's nothing for a prompt to shape. Returning empty here
    /// also means the host's `composeSystemPrompt` produces a clean
    /// no-op when this agent is briefly active during a switch.
    public func systemPrompt(for context: AgentContext) async throws -> String {
        ""
    }

    /// Drive the pipeline. Reaches the host's tool registry through
    /// `context.invokeTool`; a missing invoker is a hard error since
    /// there's nothing to fall back to (no LLM means no graceful
    /// degradation path). Tool errors short-circuit the pipeline at
    /// the failing step.
    public func customLoop(
        turn: AgentTurn,
        context: AgentContext
    ) async throws -> StepTrace? {
        guard let invoke = context.invokeTool else {
            throw AgentError.toolInvokerMissing
        }

        var bag: [String: String] = [:]
        var trace = StepTrace()

        for step in steps {
            let argString: String
            do {
                argString = try step.arguments(turn.userText, bag)
            } catch {
                let message = "argument build failed at \(step.name): \(error.localizedDescription)"
                trace.steps.append(.error(message))
                return trace
            }
            let call = ToolCall(name: step.name, arguments: argString)
            trace.steps.append(.toolCall(call))

            let result: ToolResult
            do {
                result = try await invoke(step.name, argString)
            } catch {
                let message = "tool dispatch failed at \(step.name): \(error.localizedDescription)"
                trace.steps.append(.error(message))
                return trace
            }
            trace.steps.append(.toolResult(result))

            // Surface tool-side errors as a terminal `.error` step
            // (not just a flag in the bag) so composition fallback
            // can recognise the pipeline as failed and dispatch an
            // alternative.
            if let toolError = result.error, !toolError.isEmpty {
                trace.steps.append(.error("tool \(step.name) reported: \(toolError)"))
                return trace
            }

            if let key = step.bind {
                bag[key] = result.output
            }
        }

        let finalText = output(turn.userText, bag)
        trace.steps.append(.finalAnswer(finalText))
        return trace
    }
}
