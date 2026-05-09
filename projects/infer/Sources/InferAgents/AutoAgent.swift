import Foundation
import InferCore

/// "Auto" picker entry: a synthetic compiled agent that, when active,
/// makes the chat run a `.delegate` composition each turn — the agent
/// itself is the router, and the candidate list is every compatible
/// agent in `AgentController.availableAgents` (minus Auto itself and
/// Default, see `AutoAgent.candidateIds(from:)`).
///
/// Why one compiled agent instead of two (picker entry + hidden
/// router)? The `.delegate` plan invariant is `router not in
/// candidates`; since Auto is filtered out of its own candidate set,
/// AutoAgent can safely be both the picker handle and the router.
/// A second hidden agent would add a registration step + a
/// listing-filter dance for no expressivity gain.
///
/// The candidate list is dynamic per user turn (the user can install
/// or remove personas mid-conversation) so it cannot live in this
/// agent's static `systemPrompt`. Instead, `Generation.swift`
/// pre-pends a `# Available agents` section to the router's first
/// user turn — `runDelegate`'s scratchpad logic carries that into
/// subsequent iterations automatically. AutoAgent's static prompt
/// covers the *protocol* (when to call `agents.invoke`, when to stop
/// and answer); the per-turn candidates live in user text.
public struct AutoAgent: Agent {
    public static let id: AgentID = "infer.auto"

    /// Multi-hop cap for the underlying `.delegate` plan. Conservative
    /// default per `agent_delegate.md` open question #2 — enough for
    /// outline → draft → critique → revise; low enough that a router
    /// stuck in a non-progressing loop bails fast. Configurable later
    /// via `InferSettings` if needed.
    public static let maxHops: Int = 4

    public let settings: InferSettings

    public init(settings: InferSettings = .defaults) {
        self.settings = settings
    }

    public var id: AgentID { Self.id }

    public var metadata: AgentMetadata {
        AgentMetadata(
            name: "Auto",
            description: "Routes each turn to the best-matching agent based on the request. Multi-hop: can chain agents within a single turn.",
            author: "first-party"
        )
    }

    public var requirements: AgentRequirements {
        // `.any` backend: routing logic is template-family-agnostic
        // and works with whatever model is loaded. Tool access is
        // declared so `toolsAvailable` filtering lets `agents.invoke`
        // through under the global tool catalog rules.
        AgentRequirements(
            backend: .any,
            toolsAllow: ["agents.invoke"]
        )
    }

    public func decodingParams(for context: AgentContext) -> DecodingParams {
        DecodingParams(from: settings)
    }

    public func systemPrompt(for context: AgentContext) async throws -> String {
        let base = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let protocolText = Self.routingProtocol
        if base.isEmpty { return protocolText }
        return base + "\n\n" + protocolText
    }

    /// Build the user-text prefix listing candidates. `Generation.swift`
    /// concatenates this with the user's actual prompt before calling
    /// `dispatch(plan: .delegate(...), userText: ...)`. Lives here (not
    /// in Generation) so the format stays paired with the routing
    /// protocol prompt — the model is told "look for `# Available
    /// agents`" in the protocol; this helper writes that section.
    public static func renderCandidateListing(_ candidates: [AgentListing]) -> String {
        guard !candidates.isEmpty else { return "" }
        var out = "# Available agents\n"
        for listing in candidates {
            let desc = listing.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if desc.isEmpty {
                out += "- `\(listing.id)` — \(listing.name)\n"
            } else {
                out += "- `\(listing.id)` — \(listing.name): \(desc)\n"
            }
        }
        return out
    }

    /// Compose the full router input for a given user turn. Empty
    /// candidate list returns `userText` unchanged so the router
    /// degrades to "answer it yourself" rather than failing on a
    /// missing section.
    public static func renderRouterInput(
        userText: String,
        candidates: [AgentListing]
    ) -> String {
        let listing = renderCandidateListing(candidates)
        guard !listing.isEmpty else { return userText }
        return "\(listing)\n# User request\n\(userText)"
    }

    /// Filter `availableAgents` down to viable Auto candidates: drops
    /// Auto itself (would violate `.delegate`'s router-not-candidate
    /// invariant), drops Default (the system fallback — routing to it
    /// would just defeat the point), and drops anything failing the
    /// caller-supplied compatibility check (backend / template
    /// family). The caller passes `isCompatible` because compatibility
    /// depends on the runner's currently-loaded template family,
    /// which lives on `AgentController`, not in this static helper.
    public static func candidateIds(
        from listings: [AgentListing],
        isCompatible: (AgentListing) -> Bool
    ) -> [AgentListing] {
        listings.filter { listing in
            guard listing.id != Self.id else { return false }
            guard !listing.isDefault else { return false }
            return isCompatible(listing)
        }
    }

    /// Routing protocol — prepended (or used as-is) in the router's
    /// system prompt. Explains when to dispatch via `agents.invoke`,
    /// when to stop and answer directly, and the `# Available agents`
    /// convention used in user text.
    static let routingProtocol = """
    You are a routing agent. Each user turn includes a `# Available agents` \
    section listing the candidates you may dispatch to, followed by a \
    `# User request` section with the actual request.

    Decide whether the request is best answered by one of the listed \
    candidates or by you directly:

    - If a candidate is a clear fit, call the `agents.invoke` tool with \
    `{"agentID": "<candidate id>", "input": "<the message to send the candidate>"}`. \
    The candidate's reply will be shown to the user as the final answer.
    - After a candidate has answered, you'll see its result in a \
    `# Prior dispatches` section on your next turn. Decide whether to \
    invoke another candidate (for follow-up work) or to write the final \
    answer directly. When you write a final answer instead of calling \
    `agents.invoke`, that text becomes the user's reply.
    - If no candidate is a clear fit, just answer the request yourself.

    Only the `agents.invoke` tool is available to you; do not attempt \
    other tools. Pick the most specific candidate; if multiple plausibly \
    fit, prefer the one whose description most narrowly matches the \
    request.
    """
}
