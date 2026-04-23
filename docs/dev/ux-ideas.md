# UX ideas — analysis and framing

Working document for UX directions under consideration. Each entry captures the idea as posed, a sharper reframing, the design questions it raises, and a recommendation on whether and how to pursue it. Not a commitment — a filter.

---

## Hierarchical workspace folder (agents, transcripts, images, audio)

**As posed**: if the number and type of agents grows, expose them in a hierarchical folder structure alongside transcripts, images, audio.

**Reaction**: good instinct, but cautious. The app currently treats each artifact type as orthogonal:

- Agents → `~/Library/Application Support/Infer/agents/` (flat dir of JSON).
- Transcripts → user's chosen save location + the SQLite vault.
- Images → ephemeral attachments, not persisted.
- Audio → ephemeral Whisper inputs, not persisted.

Those have different lifetimes and different natural stores. Collapsing them under one folder tree is tempting but has to answer three questions first:

1. **What's the unit?** A "project"? A "thread"? A "topic"? Without a unit, a hierarchical view degenerates into a Finder replacement — mixed types, no organizing principle. If the answer is "project" (agents + transcripts + inputs grouped per effort), that's a real, defensible model — and it's where Cursor / Zed / Warp have landed.
2. **Where does it live on disk?** Moving the vault under a project tree breaks its indexed-search story unless each project gets its own vault. Either option is a migration.
3. **What's the source of truth for "which agent is this project using"?** Today it's global (one active agent at a time). A project model implies per-project agents — a bigger refactor than the folder view. Touches `ChatViewModel`, runner lifecycle, and persistence.

**Risk**: building a filesystem-backed hierarchy where the vault-backed transcript list pretends to be a folder is the worst of both worlds. Either both live on disk (vault re-architected into per-conversation files) or the "folders" are metadata tags stored in the vault. Tag-as-folder is the smaller change and keeps search fast.

**Alternative framing**: maybe the feature isn't "folder hierarchy" but "tagging + filtering." Tags compose; folders don't. For a dataset that's going to be mixed-type and fluid (heavy re-categorization early on), tags tend to win. Worth prototyping the tag version before committing to folders.

### Minimum viable version (if pursued)

A sidebar tab ("Workspace" or "Library") showing a tree with three fixed top-level sections:

- **Agents** — today's library.
- **Transcripts** — surfaced from the vault.
- **Attachments** — a new on-disk folder for durable images / audio.

Users can create sub-folders within each. No "project" abstraction yet — just better navigation of what already exists. Living with it for a while reveals whether users actually want a real project model or just better findability.

### Recommendation

- **Do not** start a full workspace/project refactor without first deciding whether the organizing unit is the project.
- **Do** prototype tag-based organization on vault conversations as a self-contained experiment; it's a fraction of the cost and may close the gap.
- **Revisit** the folder tree only after the tag prototype has been used in anger.

---

## Terminal / console panel

**As posed**: a kind of terminal — a way to launch agents, receive errors, etc.

**Reaction**: strong yes in principle, but "terminal" collapses three different features that want different treatment.

### Three possible meanings

1. **Log console.** Read-only stream of structured events: agent switches, tool invocations, vault writes, runner errors, model loads. Today these go to stderr and are invisible unless the user launched from a shell. A log panel is *unambiguously* useful and low-risk — it's observability you already have, just surfaced. Build this first.
2. **REPL / command palette.** A prompt where you can type `switch agent code-helper`, `load gguf …`, `run tool clock_now`, etc. Useful for power users, but introduces a second input surface alongside the chat composer and competes with it for attention. Consider whether `/slash-commands` inside the composer solve the same need with less UI.
3. **Agent stdout pane.** When an agent produces "console-shaped" output (large JSON, raw tool-call traces, errors with stack), route it to this pane instead of inline in the transcript. Interesting design-wise because it changes what the transcript shows (prose + tool summaries) vs. what the console shows (raw structured data). Overlaps heavily with the existing `StepTraceDisclosure`.

### Recommendation

**(1) + hooks for (3).** Skip (2) until (1) has been lived with.

Ship a Console tab in the sidebar — or a toggleable bottom pane (think `Cmd+Shift+J` in browsers) — that:

- Streams structured events with (level, source, message, optional JSON payload).
- Replaces three current stderr-only sinks:
  - `vault write failed: …` (`ChatViewModel/Generation.swift`)
  - Whisper / speech-service warnings
  - `AgentController` bootstrap diagnostics (currently surfaced as the Agents-tab banner; could additionally be tailed here)
- Is the target for "Show details…" on tool errors: `StepTraceDisclosure` keeps its short red line; deeper output lands in the console.
- Is copyable, filterable by level/source, and kept in-memory only (no disk).

Defining a structured `LogEvent { level, source, message, payload }` type is infrastructure that pays for itself even if the console UI stays minimal — downstream features (telemetry, crash reports, a later REPL) inherit it.

---

## Sequencing across both ideas

1. **Console first.** Small, self-contained, immediately useful, low risk. Forces a structured event type that becomes infrastructure.
2. **Then tags on vault conversations.** Prototype tag-based organization as a self-contained experiment. If it covers the use cases, the workspace tree may not be needed.
3. **Only then** consider the workspace tree — and only if you've also decided whether "project" is the organizing unit.

**Explicitly avoid**: starting both in parallel. The workspace feature is an architecture question masquerading as a UI feature; the console is a UI feature masquerading as simpler than it is. Doing them together forces premature decisions on both.
