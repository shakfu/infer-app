import Foundation

/// Four-axis snapshot of a single workspace's per-workspace
/// inference-parameter overrides. Mirrors the four nullable columns
/// added to the `workspaces` table in vault schema v5
/// (`docs/dev/per-workspace-params.md`). `nil` means "this workspace
/// does not override this field" — the cascade falls through to the
/// next layer.
///
/// Lives in `InferAppCore` (not the app target) so the cascade
/// resolution is unit-testable without `@testable`-importing the
/// executable. The chat-VM constructs these from `WorkspaceSummary`
/// rows and feeds them through `resolve(...)` to produce the
/// effective values.
public struct WorkspaceParamCascade: Sendable, Equatable {
    public var systemPrompt: String?
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    /// Per-workspace output directory for generated artifacts (Phase 2).
    /// Stored as the unexpanded user input (e.g. `~/Pictures/Infer/`);
    /// callers are responsible for tilde-expansion at use time. `nil`
    /// at the active layer falls through to Default; `nil` at both
    /// means the chat-VM substitutes the legacy hardcoded path.
    public var outputDirectory: String?
    /// Per-workspace active agent / persona id (Phase 3). Stored as
    /// the raw `AgentID` rawValue (a String). `nil` at the active
    /// layer falls through to Default; `nil` at both means the
    /// synthetic `DefaultAgent.id`. Graceful degradation if the
    /// resolved id is missing from the registry or incompatible with
    /// the current backend lives in the chat-VM, not here — this
    /// type just resolves the cascade.
    public var activeAgentId: String?

    public init(
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        outputDirectory: String? = nil,
        activeAgentId: String? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.outputDirectory = outputDirectory
        self.activeAgentId = activeAgentId
    }

    /// Two-layer cascade: each field on `active` wins when non-nil,
    /// otherwise falls through to the same field on `defaults`. A nil
    /// at both layers stays nil — the caller's own fallback (typically
    /// the legacy `UserDefaults` values, or `InferSettings.defaults`)
    /// applies a final layer outside the cascade.
    ///
    /// The Default workspace's row plays the `defaults` role here.
    /// `active` is nil when no workspace is selected (boot edge case)
    /// or when the active workspace IS Default (in which case the
    /// caller passes the same row in both slots and the override
    /// behaviour collapses to identity).
    public static func resolve(
        active: WorkspaceParamCascade?,
        defaults: WorkspaceParamCascade?
    ) -> WorkspaceParamCascade {
        WorkspaceParamCascade(
            systemPrompt: active?.systemPrompt ?? defaults?.systemPrompt,
            temperature: active?.temperature ?? defaults?.temperature,
            topP: active?.topP ?? defaults?.topP,
            maxTokens: active?.maxTokens ?? defaults?.maxTokens,
            outputDirectory: active?.outputDirectory ?? defaults?.outputDirectory,
            activeAgentId: active?.activeAgentId ?? defaults?.activeAgentId
        )
    }

    /// True when at least one field is non-nil. Drives e.g. the
    /// per-field `[Use default]` button's render gate at the call
    /// site (the button only appears when there's something to
    /// clear).
    public var hasAnyOverride: Bool {
        systemPrompt != nil
            || temperature != nil
            || topP != nil
            || maxTokens != nil
            || outputDirectory != nil
            || activeAgentId != nil
    }
}
