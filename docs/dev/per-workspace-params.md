# Per-workspace parameters — design scope

**Status:** design, not implemented. Resolved decisions captured
inline. Open questions surfaced in §9. Scope expanded in §12 to cover
MCP servers, persona/agent/tool selection, wiki context settings, and
workspace-specific output directory — see §12 for phasing.

## 1. Goal

Today `InferSettings` (`InferCore/Settings.swift:212-215`) holds
`systemPrompt`, `temperature`, `topP`, `maxTokens` in a single global
slot persisted to `UserDefaults`. Workspaces (`Vault.swift:11-23`)
scope name + RAG corpus + wiki dir + conversations but not these.

The natural feature gap: a "coding assistant" workspace and a
"creative writing" workspace want different system prompts (and
arguably different temperatures), but today flipping between them
forces the user to manually rewrite the global slot every time. The
right cut is **global defaults + per-workspace overrides** — global
stays as the fallback; each workspace can override any subset.

## 2. Scope (what becomes per-workspace)

| Field | Per-workspace | Why |
|---|---|---|
| `systemPrompt` | yes | strongest case — workspace = working context |
| `temperature` | yes | different tasks want different creativity |
| `topP` | yes | coupled to temperature, same case |
| `maxTokens` | yes | output budgets diverge per task |
| backend (`llama` / `mlx` / `cloud`) | no | global; workspaces don't dictate runtime |
| model id (per backend) | **out of scope** | natural follow-up; defer |
| TTS / voice / appearance / window | no | global |

Per-workspace-per-backend params (e.g. different system prompt on MLX
vs. Cloud) deliberately out of scope — system prompt is a
backend-agnostic intent. Punt unless we hit a real case.

## 3. Override semantics

**Default workspace IS the global defaults.** There is no separate
`UserDefaults`-backed global slot in the new model. The Default
workspace's row in the `workspaces` table holds the globals; every
other workspace inherits from it via per-field nullable columns.

**Sparse / nullable on non-Default workspaces.** Each per-workspace
field is `Optional`; `nil` means "fall back to Default."

```swift
// effective settings the runner receives:
effective.systemPrompt = activeWorkspace.systemPrompt
                      ?? defaultWorkspace.systemPrompt
// same for temperature, topP, maxTokens
```

Default workspace's columns are conceptually non-nullable — they're
the floor — but enforced at the read layer (vault helper substitutes
the legacy `UserDefaults` value if a row's column is `NULL`, which
happens only during the v5 migration window).

Rejected alternative A: full-snapshot at workspace creation. Cleaner
data model but two real downsides — (a) Default-edits don't propagate
to existing workspaces, surprising users who tune Default expecting
an app-wide effect; (b) the "reset to default" UX requires
remembering what the original snapshot was, vs. clearing one nullable
column.

Rejected alternative B: keep `UserDefaults` as the global source,
have Default workspace also have nullable overrides over it. Adds a
layer that exists only to be transparent — Default IS where you'd go
to edit the globals anyway.

## 4. Persistence (vault schema v5)

Four nullable columns on `workspaces`:

```sql
ALTER TABLE workspaces ADD COLUMN system_prompt TEXT;
ALTER TABLE workspaces ADD COLUMN temperature   REAL;
ALTER TABLE workspaces ADD COLUMN top_p         REAL;
ALTER TABLE workspaces ADD COLUMN max_tokens    INTEGER;
```

`NULL` = use global. Migration is additive (no data rewrite). The v4
backfill that creates the Default workspace stays as-is — Default
launches with all four columns `NULL` so existing users see exactly
the current behaviour until they edit something.

`WorkspaceSummary` gains the four optionals. Vault read/write helpers
extend to round-trip them. `EffectiveSettings` is a thin compose
helper, not a stored type.

## 5. UI surfaces

**Right sidebar Parameters disclosure is the single editing surface.**
The active workspace dictates the target — no toggles, no modality:

- Default workspace active → edits write to Default's row (= the
  globals, in the new model).
- Any other workspace active → edits write to that workspace's row.

Per-field `[Use default]` buttons appear on the right sidebar whenever
a non-Default workspace is active, one per field that currently has an
override. Clicking clears the workspace's column for that field; the
sidebar value updates to show Default's value (the new effective).
Default workspace doesn't need these buttons — there's nothing higher
to fall back to.

Field placeholders show what the field would inherit if not overridden,
so the user always knows what they're departing from:
`"(default: be helpful and terse)"`.

`WorkspaceSettingsInline` (the workspace sheet opened from the sidebar
picker) does **not** duplicate the inference fields. It stays scoped
to workspace identity (name, dataFolder, RAG corpus controls) — params
are an active-workspace concern, edited where they're seen and
applied.

Rejected alternative: a workspace-scope toggle on the right sidebar
(`Editing: [Workspace] | Defaults`). Adds modality the user has to
remember; the active-workspace-implies-target rule is more
discoverable.

Rejected alternative: duplicate the four fields in the workspace
sheet. Two editing surfaces for the same data invites drift and
confusion.

Friction note: editing the globals now requires switching to Default
first. That's one extra click per "I want to change my default
temperature" event, vs. always-available today. Acceptable cost for a
materially cleaner mental model. A future "promote workspace's params
to Default" button can mitigate if the friction shows up in practice.

## 6. Workspace switch flow

Conversations are already workspace-scoped — switching workspace
clears the chat (`reset()` equivalent). The new flow:

1. User picks W2 in the workspace picker.
2. Chat clears; vault saves prior W1 conversation as today.
3. Compute `effective = W2.params.applied(over: global)`.
4. `applySettings(effective)` — same single entry point as today,
   so each runner's `updateSettings` / `updateSampling` paths fire as
   before.
5. New conversation starts fresh against the new effective settings.

Critically: **workspace switch does NOT trigger the F-3 history-loss
class.** The chat is being abandoned by design at the boundary, so
runner state being rebuilt is correct. F-3 still matters for the
slider-drag and workspace-sheet-edit cases (§9).

## 7. Edits while a conversation is in flight

Two new vectors for the F-3 class:

- User opens the workspace sheet, edits the system prompt, hits
  Apply, mid-conversation. Effective settings change; runner rebuilds.
- User edits the right-sidebar global params, mid-conversation, while
  a workspace has overrides for those fields. **No-op for the
  effective settings** — the global change is masked by the override.
  Free win: many global tweaks become invisible to the runner when a
  workspace overrides the same field. Less rebuilding, less F-3.

The per-workspace edit case is the same shape as today's slider-drag
case. Solving F-3 for one solves it for both. This design does NOT
solve F-3; it just doesn't make it worse.

## 8. Migration / rollout

- Vault migration v4 → v5 adds the four columns.
- Existing workspaces get `NULL` everywhere → effective settings ==
  global → behaviour unchanged on upgrade.
- Default workspace stays special only in name / delete-protection;
  it can carry overrides like any other.
- Workspace delete cascades the override columns (single row, free).
- Workspace reset (the existing orange button on Default) — open
  question: should it clear overrides? Argument for yes: "reset"
  today wipes wiki + RAG, clearing overrides is consistent. Argument
  for no: overrides are a curated user input, distinct from
  generated content. **Default: clear overrides on reset** unless
  user input says otherwise.

## 9. Open decisions

Resolved during scoping:

- **Granularity:** per-field `[Use default]`. Confirmed.
- **Right-sidebar target:** the active workspace dictates — Default
  → globals, other → workspace. No toggle. Confirmed.
- **Default workspace IS globals:** the data model has one row that
  serves as the floor; non-Default workspaces hold sparse overrides
  over it. Confirmed.

Resolved:

- **Workspace reset is now narrowly scoped to params** — it clears the
  four per-workspace columns and leaves wiki pages, RAG corpus,
  conversations, name, and `data_folder` intact. Initial design had
  reset wiping wiki + RAG too "for consistency"; revised after
  scoping to recognise that wiki content is curated user authoring,
  not generated state, and conflating it with param-reset is
  surprising. For Default the four columns clear to NULL, which
  restores the hard-coded `InferSettings.defaults` floor; for
  non-Default the sparse overrides clear and the workspace falls
  back to Default. The button label is now "Reset parameters"
  rather than "Reset workspace" to match.
- **New workspace creation: all NULL.** New workspaces inherit live
  from Default. Tuning Default later propagates immediately. Sparse
  overrides set on first edit.

Still open:

1. **Per-conversation snapshot.** Should the vault record the
   effective params at the time each conversation was created, so
   reopening a 6-month-old conversation restores its sampling
   environment? Out of this scope but it's the natural next layer.
   Flag for a future doc; do not build now.

## 10. Cost / effort estimate

| Piece | Effort |
|---|---|
| Vault migration v5 + read/write helpers + `WorkspaceSummary` extension | ~1h |
| One-time migration of legacy `UserDefaults` globals into Default's row | ~30m |
| `EffectiveSettings` compose + chat-VM wire-up | ~1h |
| Right-sidebar reads/writes the active workspace; per-field `[Use default]` | ~1.5h |
| Workspace switch wires through `applySettings` (largely existing) | ~30m |
| Tests (vault round-trip, compose semantics, switch flow, fallback chain) | ~1.5h |
| **Total** | ~6h |

Independent of F-3. Lands cleanly before or after — the fix to F-3
generalises across both global and per-workspace edit triggers without
this design needing to know about it.

## 11. Out of scope (for clarity)

- Per-workspace model selection (separate feature; bigger).
- Per-conversation param snapshots (decision 1 above; future).
- Per-backend overrides within a workspace.
- Importing / exporting workspace param sets as JSON.
- A "system prompt presets" library (TODO.md P1) — orthogonal; can
  stack on top by letting the system-prompt field pick from presets.

## 12. Expanded scope: workspace as full working context

The scope above (sampling params + system prompt) is the simplest
case. The user's broader intent: a workspace should encapsulate **the
entire runtime context of a chat** — MCP servers, persona / agent
selection, tool availability, wiki context budget, RAG corpus, and
output directory. This section catalogues each axis, calls out what's
already per-workspace today, and proposes a phasing.

### 12.1 Inventory

| Axis | Today | Per-workspace target | Schema impact |
|---|---|---|---|
| `systemPrompt`, `temperature`, `topP`, `maxTokens` | global (`UserDefaults`) | nullable scalar / text columns; Default's row = floor | 4 columns (in §4) |
| Active agent / persona | `AgentController.activeAgentId`, persisted globally | nullable `active_agent_id TEXT` column on `workspaces` | 1 column |
| Wiki inject budget (`wikiBudgetTokens`) | global (`UserDefaults`) | nullable `wiki_budget_tokens INTEGER` | 1 column |
| Pinned wiki pages | already per-workspace (in `WikiStore`) | unchanged | none |
| Wiki directory | already per-workspace (`WikiStore` paths) | unchanged | none |
| RAG corpus (`dataFolder`) | already per-workspace (`workspaces.data_folder`) | unchanged | none |
| RAG vector store contents | already per-workspace (scoped by `workspace_id`) | unchanged | none |
| MCP servers (`~/.config/infer/mcp/`) | global config dir, all servers loaded for every workspace | per-workspace **enable list** over the global config dir | join table or JSON column |
| Tool registry (built-in + plugin + MCP-derived) | global, all enabled | per-workspace **enable list** | join table or JSON column |
| Compiled agents (registry) | global, all available | per-workspace **enable list** | same as above (or per-tool/agent allow-list) |
| Output directory (SD images, exports) | global (`Application Support/Infer/...`) | nullable `output_directory TEXT` column | 1 column |

Three of these axes (pinned pages, wiki dir, RAG corpus) are already
per-workspace and need no work. The rest split into two patterns.

### 12.2 Pattern A — sparse scalar override

Same shape as the original §3 design. Default's row holds the floor;
non-Default's nullable column overrides per field. Cleanly applies to:

- `systemPrompt`, `temperature`, `topP`, `maxTokens`
- `wikiBudgetTokens`
- `outputDirectory`
- `activeAgentId` — but with one wrinkle (§12.5).

### 12.3 Pattern B — set / allow-list

MCP servers, tools, and agents are *collections*, not scalars. The
override question is "which subset of the global catalogue is active
in this workspace?" Two reasonable models:

- **Allow-list per workspace.** Workspace stores `[String]` of
  enabled ids; `nil` means "all from the global catalogue." Edits
  flip individual ids in/out. Clean fallback to "everything," easy
  to migrate (existing workspaces get `nil`).
- **Deny-list per workspace.** Workspace stores ids it *disables*.
  Inverse of allow-list. Easier when the user mostly wants the
  global set with a few exceptions.

Allow-list is more honest about user intent (user explicitly picks
what's available) and matches how the right sidebar's existing
agent picker / tools list already feel. Going with allow-list,
nullable: `NULL` = inherit Default; `[]` = nothing enabled (workspace
explicitly silenced this axis); `[...ids...]` = the named subset.

For Default workspace, `NULL` on these set columns has a special
read: "all from the global catalogue." Default acts as the floor for
scalar axes (Pattern A) and as the implicit "everything" for set
axes (Pattern B). When the user edits Default's allow-list, it
becomes an explicit set; non-Default workspaces with `NULL` still
inherit it.

Storage: a single `JSON TEXT` column per axis is simplest (one read,
one write, no join). Trade-off: not query-friendly for "which
workspaces enable MCP server X" — but the app doesn't have that
query today, so no real loss. If a join becomes useful later, a
side table is an additive migration.

Three new nullable JSON columns: `enabled_mcp_servers`,
`enabled_tools`, `enabled_agents`.

### 12.4 Pattern C — output directory

Special case of Pattern A but with filesystem semantics. Storage is
a nullable string. Read time: if non-empty, expand `~` and use; if
nil, fall back to Default's column; if Default's is also nil, use
the legacy `Application Support/Infer/output/` path. Migration
populates Default's column with the legacy path so existing users
see no change. Subdirectories (SD output, transcript exports,
generated artifacts) compose under whichever effective directory
applies.

Edge case: switching workspaces mid-generation. The output directory
that was active when the generation started is what gets used; in-
flight generations don't relocate. The current `sd.swift` capture of
the destination URL is already a snapshot; verify and document.

### 12.5 Active agent — wrinkle

`activeAgentId` is *also* shaped like a scalar override, but with a
different switch flow than sampling. Today, switching the active
agent fires `AgentController.activate(agentId:)` which mutates a lot
of state (decoding params, tool availability, system-prompt
adjuncts). Per-workspace + workspace-switch flow:

1. User switches W1 → W2.
2. Effective `activeAgentId = W2.activeAgentId ?? Default.activeAgentId`.
3. If effective changed from W1's, fire `AgentController.activate`
   with the new id.
4. Compatibility check: if W2's pinned agent is no longer compatible
   with the active backend (e.g. requires tools the workspace's
   allow-list now disables), fall back to Default's pinned agent;
   if that also fails, fall back to `DefaultAgent.id`.

So persona-per-workspace composes with tools-per-workspace and needs
the activation pipeline to know how to gracefully degrade. Not hard,
but worth documenting because it's where most edge cases will hide.

### 12.6 UI surfaces (expanded)

Right sidebar remains the single editing surface for axes already
shown there:

- **Parameters** disclosure: §5's per-field `[Use default]` extends
  to `systemPrompt` / `temperature` / `topP` / `maxTokens` /
  `wikiBudgetTokens` / `outputDirectory`.
- **Agents tab**: existing persona/agent picker now writes to the
  active workspace's `activeAgentId`. The library list itself shows
  the workspace's enabled subset; an "all agents" toggle reveals the
  global catalogue with checkboxes for editing the allow-list.
- **MCP servers tab**: existing list grows a per-server enable
  checkbox bound to `enabled_mcp_servers`. A "show only enabled"
  toggle filters the view.
- **Tools settings** (`ToolsSettingsView`): per-tool enable
  checkboxes bound to `enabled_tools`. The existing per-tool output
  cap stays global (for now; could become per-workspace later).

`WorkspaceSettingsInline` (the sheet) gains the **output directory**
field — that's the only axis that's a one-shot identity-style setting
rather than something the user toggles during a session. Everything
else stays in the right sidebar where the user is already living.

### 12.7 Phasing recommendation

Trying to land all of this in one PR is a 20-25h diff that touches
the chat-VM, vault, agent controller, MCP host, tool registry, SD
runner, sidebar UI, settings UI, and migration. Failure mode is a
half-baked feature where two axes work and three don't. Better:

**Phase 1 (the original §1-§11 design, ~6h):** sampling +
`systemPrompt` only. Establishes the migration shape, the per-field
`[Use default]` pattern, the sidebar-target-follows-active-workspace
rule, the read-time fallback chain. Lands as one coherent feature.

**Phase 2 (~3h):** scalar additions — `wikiBudgetTokens`,
`outputDirectory`. Pure replication of Phase 1's shape; no new
patterns.

**Phase 3 (~5h):** `activeAgentId` per-workspace, including the
graceful-degradation path on workspace switch. Touches
`AgentController` and the right sidebar's agent picker. Tested
against the existing agent-listing tests.

**Phase 4 (~6h):** the three set / allow-list axes (`enabled_mcp_servers`,
`enabled_tools`, `enabled_agents`). New JSON-column pattern; needs
new migration columns, new helpers, and UI for editing the allow-
lists. Most novel of the phases.

**Phase 5 (~2h):** polish — empty-state copy, sidebar badges,
documentation in CHANGELOG.

Total ~22h across five logical commits. Each phase is independently
shippable; users see incremental value; rollback risk per phase is
small. Phase 1 alone delivers the headline feature you asked about.

### 12.8 Open questions for the expanded scope

1. **Allow-list vs deny-list for set axes.** Recommendation: allow-
   list (§12.3). Confirm.
2. **Default workspace's set-axis semantics.** When Default's
   `enabled_tools` is `NULL`, does that mean "all tools from the
   plugin / MCP catalogue"? Recommendation: yes — `NULL` on Default
   means "the unfiltered global catalogue"; explicit `[ids]` makes
   it a curated subset. Confirm.
3. **Output directory on first launch.** Migrate Default's column to
   the legacy `Application Support/Infer/` path so existing users
   see no change? Or leave it `NULL` and let read-time substitute
   the legacy default? The latter is cleaner (no migration data
   write) but means the user can't see "this is what's effective"
   in the field unless we render a placeholder. Recommendation:
   `NULL` + placeholder shows the path. Confirm.
4. **Phasing — ship Phase 1 alone, or hold for the bundle?** This
   is the big call. Phase 1 is ~6h and self-contained; the rest
   stacks on top without rework. Shipping Phase 1 alone gets the
   headline feature in front of you for use; the remaining phases
   inform their own design as you live with it.
