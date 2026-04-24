# Agent UI Overhaul — Implementation Plan

Below is a complete, phased plan covering P0 → P2. Each work item lists: **scope**, **files touched**, **new types/state**, **test coverage**, and **risks**. Sequencing is important: later items depend on abstractions introduced in earlier ones.

---

## Phase 0 — Foundations (prereq for everything)

### 0.1 Display-label on `AgentListing`
Replace ad-hoc `labelize` in `ChatTranscript.swift:260-265` with a stable, Unicode-safe label computed once.

- **Files**: `InferAgents/AgentTypes.swift` (add `displayLabel: String` to `AgentListing`, computed from `name` using `CharacterSet.alphanumerics` + lowercased, joined with `-`; fallback to `id`); `AgentRegistry` populates it; `ChatTranscript.swift` reads `message.agentLabel` (snapshot on send, same as `agentName`).
- **Tests**: `InferCoreTests` — emoji, CJK, whitespace-only, empty name fallback to id.
- **Risk**: low. Persisted transcripts already snapshot `agentName`; add `agentLabel` as optional with a migration-free default.

### 0.2 `AgentEvent` stream from `AgentController`
Introduce an `AsyncStream<AgentEvent>` so the UI can observe tool-loop progress incrementally instead of reading a post-hoc `StepTrace`.

- **New type** (`InferAgents/AgentEvent.swift`):
  ```swift
  public enum AgentEvent: Sendable {
      case assistantChunk(String)
      case toolRequested(ToolCall)
      case toolRunning(name: String)
      case toolResulted(ToolResult)
      case finalChunk(String)
      case terminated(StepTrace.Step)   // finalAnswer | cancelled | error | budgetExceeded
  }
  ```
- **Files**: `AgentController.swift` exposes `events: AsyncStream<AgentEvent>` (or returns one per `runTurn`); `ChatViewModel/Generation.swift` consumes events and mutates `messages[i].steps` incrementally.
- **Migration**: `maybeRunToolLoop` refactored to emit events rather than stamping the trace at line 242 atomically.
- **Tests**: `InferAgentsTests` — sequence of events for (a) no-tool turn, (b) tool success, (c) tool error, (d) cancelled mid-tool.
- **Risk**: medium. Touches the hot path. Keep the final `StepTrace` identical so transcript persistence is unchanged.

### 0.3 Bootstrap diagnostics
Collect parse errors during `AgentController.bootstrap` so they can be surfaced in-UI.

- **New type**: `AgentLibraryDiagnostic { url: URL; reason: String; severity: .skipped | .warning }`.
- **Files**: `InferAgents/AgentRegistry.swift` (collect), `AgentController.swift` (expose `diagnostics: [AgentLibraryDiagnostic]`), `ChatViewModel/Agents.swift` (cache on vm).
- **Tests**: malformed JSON, missing required fields, incompatible schema version.

---

## Phase 1 — P0: Header picker + streaming traces

### 1.1 Header agent picker
First-class picker adjacent to the model picker in `ChatHeader.swift`.

- **Files**:
  - `ChatView/ChatHeader.swift` — add `agentPicker` view between `statusView` and `tokenIndicator`.
  - New file `ChatView/AgentPickerMenu.swift` — menu-style button that:
    - Shows current agent name + a `tools: N` chip (N from `agentController.activeToolSpecs.count`).
    - Menu lists compatible agents first, then incompatible (greyed, with reason as subtitle via `Text` + secondary style).
    - Bottom item: "Manage agents…" opens the sidebar on the Agents tab (`sidebarOpen = true; sidebarTab = .agents`).
  - `ChatViewModel.swift` — expose `currentAgentToolCount: Int`.
- **Keyboard**: register `Cmd+Shift+A` in `Infer/Commands.swift` (or the existing `.commands` builder) to open the picker.
- **Behaviour**: selecting an agent calls `vm.switchAgent(to:)`. Picker closes immediately; the divider appears in the transcript as today.
- **Tests**: snapshot-ish via `@Observable` — unit-test that selecting a listing in the picker invokes `switchAgent` with the right id. No UI test infra today, so this is a light view-model test.
- **Risk**: low. Additive; doesn't remove sidebar tab.

### 1.2 Streaming tool-loop visualisation
Consume 0.2's `AgentEvent` stream and render progress live in the transcript.

- **Files**:
  - `ChatView/ChatTranscript.swift` — `StepTraceDisclosure` (lines 272-309) rewritten:
    - Auto-expands while the turn is `in-progress` (message matches the currently-streaming `assistantIndex`).
    - Auto-collapses 500 ms after `terminated`.
    - Adds a running spinner + `"running \(toolName)…"` row between `toolRequested` and `toolResulted`.
  - `Infer/ChatModels.swift` — `ChatMessage` gains `isStreaming: Bool` (mirror of vm's `isGenerating && index == assistantIndex`). Alternative: derive from the absence of `trace.terminator`.
  - `Generation.swift` — on each `AgentEvent`, mutate `messages[assistantIndex].steps` append/replace appropriately.
- **Setting**: add `Settings.autoExpandAgentTraces: Bool` (default `true`). Persist in `UserDefaults` via existing `PersistKey` machinery.
- **Tests**: view-model test that drives a mock `AgentEvent` sequence and asserts the final `steps` array matches the atomic pre-refactor output (bytewise equal) — guarantees no regression in persisted format.
- **Risk**: medium. Re-renders are frequent; batch SwiftUI updates via `withAnimation(nil)` or by mutating in-place rather than replacing the whole `ChatMessage`.

### 1.3 Header status chip for active agent
Minimal even without the picker: in the header, always show the current agent name + `tools: N` chip. Tapping it opens the picker.

- Folded into 1.1's picker button label; no separate file needed.

**Phase 1 exit criteria**: user can switch agents in ≤1 click from the chat view; tool invocations stream visibly with a spinner; active agent is legible without opening the sidebar.

---

## Phase 2 — P1: Inspector, direct activation, error surfacing

### 2.1 Agent inspector panel
Click a row (not just the menu) to reveal a read-only detail panel.

- **Files**:
  - New `Sidebar/AgentInspectorView.swift` — sections:
    1. **Header** — name, description, source, author.
    2. **System prompt** — `DisclosureGroup`, `TextEditor`-styled-read-only (selectable, monospaced).
    3. **Tools** — list of `ToolSpec` names + short descriptions from `ToolCatalog`.
    4. **Decoding overrides** — temperature / topP / maxTokens diffed against `settings` (show `→` only when overridden).
    5. **Compatibility** — backend/template requirements + live status against current backend.
    6. **Actions** — `Activate`, `Duplicate as user agent`, `Preview change…`, `Reveal JSON in Finder`, `Edit JSON…`.
  - `AgentsLibrarySection.swift` — row becomes a `NavigationLink` / `Button` that toggles an `@State var selectedListing: AgentListing?`; inspector renders in a sheet (fallback on `popover` for macOS) or an inline disclosure below the row.
- **State**: `ChatViewModel` exposes `inspectorListing: AgentListing?` for programmatic open (e.g., from picker's "Manage…").
- **Tests**: controller-level tests for diff computation (`DecodingParams.diffed(against:)`).
- **Risk**: low-medium. macOS sheets work but the app currently has none — verify with a small spike.

### 2.2 Preview-before-switch
Diff view showing what changes on agent activation.

- **Files**: `AgentInspectorView.swift` — "Preview change" button computes:
  - System prompt diff (before → after) — render with `swift-markdown-ui` monospaced code blocks, no highlighter.
  - Tools added / removed.
  - Sampling diff.
- **Decision surface**: single `Activate` button at the bottom of the preview. `Cancel` closes the sheet.
- **Tests**: pure-function diff helpers in `InferCoreTests`.
- **Risk**: low.

### 2.3 Direct activation (row click)
Replace the ellipsis menu's primary action.

- **Files**: `AgentsLibrarySection.swift` — row background becomes a button; primary click activates (or opens inspector if incompatible — to explain). Ellipsis menu keeps `Duplicate`, `Reveal JSON`, `Edit JSON`, `Delete` (new, user agents only).
- **Delete** writes to a trash-safe path: `NSWorkspace.recycle(_:completionHandler:)`. Show a confirmation alert.
- **Tests**: view-model test for `deletePersona` existence + Finder integration manual.
- **Risk**: low. The user will confuse the row click with row-selects-for-focus; mitigate with a subtle hover state.

### 2.4 Library diagnostics surface
Consume 0.3's diagnostics in the Agents tab.

- **Files**: `AgentsLibrarySection.swift` — a dismissible yellow `DisclosureGroup` at the top when `!diagnostics.isEmpty`:
  - Summary: `"3 persona files skipped"`.
  - Rows: filename + reason + "Reveal" button.
- **Tests**: covered by 0.3.
- **Risk**: none.

### 2.5 Duplicate-success toast
Non-modal feedback after `duplicatePersona`.

- **Files**:
  - New `Infer/ToastCenter.swift` — `@Observable` minimal toast manager (1 toast at a time, 4 s auto-dismiss). SwiftUI overlay in `ChatView`.
  - `Agents.swift:236` — replaces the bare `NSWorkspace.activateFileViewerSelecting` with toast + "Reveal" action button.
- **Tests**: toast manager unit tests (enqueue, auto-dismiss, manual dismiss).
- **Risk**: low. Reused for future non-modal feedback (vault errors, model load errors).

### 2.6 Incompatibility tooltips in menu
Bring `vm.incompatibilityReason(listing)` into the menu item via `.help(...)` on disabled items (not just the row caption).

- Trivial diff in `AgentsLibrarySection.swift:128-130`.

**Phase 2 exit criteria**: user can inspect any agent's config from the UI, preview a switch before committing, and see feedback for every destructive/creative action.

---

## Phase 3 — P2: Composer polish, transcript affordances, ergonomics

### 3.1 Composer agent chip
Small chip in the `ChatComposer` footer (adjacent to token counter) showing active agent; click opens the header picker's menu.

- **Files**: `ChatView/ChatComposer.swift` — add `agentChip` view. Reuse `AgentPickerMenu` from 1.1.
- **Setting**: `Settings.showComposerAgentChip: Bool` (default `true`).
- **Risk**: layout — composer is already dense. Prototype first.

### 3.2 Transcript hover-detail on `AgentDividerRow`
Hovering an agent-switch divider shows the prompt/tools delta (same diff helpers as 2.2).

- **Files**: `ChatTranscript.swift:373-396` — add `.help(...)` with a textual summary, or `.popover` on click.
- **Risk**: popovers during scroll can misbehave; prefer `.help`.

### 3.3 Quicksearch over the Agents library
`TextField` at the top of `agentsLibrarySection` filters across name + description + source.

- **Files**: `AgentsLibrarySection.swift` — add `@State var search: String`; short-circuits groups with no matches.
- **Risk**: none.

### 3.4 Keyboard shortcuts
- `Cmd+Shift+A` — open agent picker (wired in 1.1).
- `Cmd+Shift+I` — open inspector for current agent.
- `Cmd+Option+1..9` — activate Nth agent from the compatible list.
- **Files**: `Infer/Commands.swift` (or wherever app commands live — verify).

### 3.5 Agent-aware composer hints
When the active agent declares requirements (e.g., vision), show a passive hint in the composer ("Vision-capable · drop an image to include"). Reuses existing `AgentRequirements`.

- **Files**: `ChatComposer.swift`; `InferAgents/AgentTypes.swift` may need a `composerHint: String?` on `AgentRequirements`.

### 3.6 "One-click fix" for incompatibility
When an incompatible agent's only mismatch is backend, offer `Switch to <backend> and activate` in the inspector.

- **Files**: `AgentInspectorView.swift`; reuses `vm.setBackend(_:)` + `switchAgent`.
- **Risk**: backend switch is non-trivial (model reload). Gate behind an alert.

**Phase 3 exit criteria**: agents feel woven into the main chat flow, not parked in a sidebar.

---

## Cross-cutting

### Testing strategy
- Unit-testable layers get unit tests (`InferAgentsTests`, `InferCoreTests`): event-stream shape, diff helpers, display-label, diagnostics, toast manager.
- SwiftUI views: no harness today. Extract testable logic into view-models where cost-effective; otherwise rely on `make test` for regression and manual QA checklist (below).

### Manual QA checklist (end of each phase)
- Launch cold → default agent selected → chip shows in header.
- Switch agent via picker → divider appears, prompt changes, no flash of wrong state.
- Send a tool-triggering prompt → spinner renders → trace populates incrementally → final answer streams.
- Malformed JSON in user agents folder → diagnostic visible in sidebar; other agents still listed.
- Duplicate → toast → Finder reveals the new file.
- Delete → confirmation → file in Trash → list updates.
- Regenerate + edit-last-user flows still work mid-tool-call.

### Persistence compatibility
- `ChatMessage.steps` persisted shape unchanged (0.2 guarantees bytewise equality of final trace).
- `AgentListing.displayLabel` is computed; not persisted — safe.
- New `Settings.*` keys use the existing `PersistKey` namespace.

### Swift-6 concurrency
New `AsyncStream<AgentEvent>` in `AgentController` must respect the `.v5` opt-out in `Package.swift:36`. Keep event types `Sendable`. `AgentController` is already an `actor` — stream creation/termination stays inside it.

### Estimated effort
- Phase 0: ~1 day.
- Phase 1: ~2-3 days (streaming refactor is the bulk).
- Phase 2: ~2-3 days.
- Phase 3: ~1-2 days.

Total ~7-9 focused days.
