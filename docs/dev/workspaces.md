# Workspaces — analysis and framing

Working document exploring the organizational model for the app as the number of transcripts, agents, and associated artifacts grows. Supersedes the "hierarchical workspace folder" entry in `ux-ideas.md`, which was framed too narrowly as "project folder" and conflated multiple axes of organization into a single hierarchy.

---

## The real question

How many organizing axes does the app need?

Consider a business environment: a manager tracks multiple companies (A, B, C, …), has per-entity analytical concerns (financials, trend-tracking, anomaly detection, deck generation), produces and consumes artifacts at each concern (inputs, outputs, intermediate runs, scheduled re-runs), and works in different contexts ("quarterly review of company A" vs. "monthly anomaly sweep across all companies").

Four structures are in play:
- **Entities being tracked** (companies).
- **Analytical concerns** per entity.
- **Artifacts** at each concern.
- **Work contexts** the user is currently in.

Companies × concerns is already a 2D grid; add time and it's 3D. A single hierarchy forces you to pick one axis as primary and lose the others.

---

## Folder-project vs. workspace

The earlier "project as a folder" framing fails this test. Reframing "project" as a **workspace** — a *composable view* made of filters, pinned agents, and scoped artifacts, where a user can have many open at once — resolves the axis problem.

| Folder-project | Workspace |
|---|---|
| Artifacts live *inside* one project | Artifacts tagged with any number of facets (company, concern, time) |
| Cross-project views are hard | "Anomalies across A, B, C this quarter" is a query, not a move |
| One active at a time | Many open simultaneously, each in its own tab/window |
| Moves between projects are copies | No moves — facets change, artifacts stay |

### Proposed model

- **Artifacts** (conversations, agents, attachments, outputs) are the storage layer — they carry facets, not locations.
- **Facets** (tag-like, but typed: `company=acme`, `concern=financials`, `quarter=2026Q1`) are the query layer.
- **Workspaces** are saved views over facets + pinned agents + preferred model + default system prompt. Many can be open.

A workspace is closer to a browser tab than a filesystem folder. "Acme Q1 review" is a workspace. "Anomaly sweep" is a workspace. The same conversation can show up in both.

---

## Multi-workspace UI

SwiftUI macOS offers two natural expressions:

1. **Multiple windows, one workspace each.** Standard macOS pattern: `File > New Workspace`, every window is independent, state survives Quit via per-window persistence. Fits the manager-reviewing-three-companies-in-parallel case. Cheap to implement — `WindowGroup` with a binding.
2. **Tabbed workspaces in one window.** Like browser tabs across the top of the content area. Good for frequent context-switching without cluttering the dock. More UI work.

Probably both, with (1) first. macOS already treats `Cmd+N` → new window as first-class.

---

## Agents under this model

Three tiers, not a flat list:

- **Global agents** — `Default`, first-party personas, any compiled conformance. Always available.
- **User library** — personas the user authored, available everywhere.
- **Workspace-pinned agents** — a workspace declares "these agents are relevant here," which filters the header picker to the working set.

An agent isn't owned by a workspace; it's *made relevant* by one. The same agent can be pinned to many workspaces. This makes `financial-analyst` usable on company A today and company B tomorrow without copying.

---

## Code shape

Rough sketch, concrete enough to cost:

- **Facets table** — `facets { id, kind, value }`; `conversation_facets`, `agent_facets` join tables. `kind` is typed (`company`, `concern`, `quarter`, free-form `tag`) so the UI can render pickers instead of just text chips.
- **Workspaces table** — `workspaces { id, name, facets_filter (JSON), pinned_agents (JSON), default_model, default_system_prompt, created_at }`. Saved views, editable, renameable, deletable.
- **`ChatViewModel` becomes per-workspace.** One VM per window or tab. Runner actors stay shared (a single llama context per process — two workspaces using the same model would otherwise re-load it). Sampling + system prompt come from the active workspace, not global settings.
- **Window management.** `WindowGroup(for: WorkspaceID.self)` with a deep-link-style binding. `File > New Workspace` creates one; a workspace switcher ("recent" + "all") in the header replaces today's single-VM world.
- **Attachments, finally real.** On-disk `Infer/attachments/`, metadata rows in the vault, facet-tagged same as conversations. Re-droppable across workspaces.

"Project" and "workspace" fully collapse here. Folder-style grouping → a workspace with a `project=acme` facet. Cross-cutting view → a workspace without. Projects are a special case.

---

## Paths forward

This is an architectural migration, not a feature sprint. Not shippable as one PR. Two honest paths:

### Path A — commit to the workspace model

Redesign around facets + multi-workspace windows. Tags become typed facets; the current flat-tag code is the migration starting point, not wasted. Biggest leverage, biggest change. 2–3 weeks focused work plus careful migration testing.

### Path B — add facets without multi-workspace yet

Ship typed facets on conversations and agents, with a rich filter UI (company facet + concern facet + date facet), all in one window. Validates whether facets-over-folders is the right model before paying for window management. Ship-in-a-week scope. The data model is exactly what Path A needs — no work is discarded.

### Recommendation

Path B as a stepping stone to Path A. Faceted single-window delivers ~80% of the organizational payoff at ~30% of the complexity, and the typed-facets schema is the foundation Path A requires. Sequencing avoids committing to window-management work before validating the data model.

---

## Open questions

Before committing to either path, resolve:

- **Typed facets vs. free-form tags.** Types give pickers and structured queries but require the user to declare kinds up front. Free-form tags with a convention (`company:acme`) give flexibility but lose the type-driven UI. Typed-with-escape-hatch (a generic `tag` kind alongside user-declared kinds) is probably right.
- **Workspace persistence granularity.** Window position + size? Sidebar tab? Scroll position in the transcript? Too much state and switching workspaces feels heavy; too little and workspaces feel like glorified filters.
- **Agent pinning vs. facet-matching.** Should an agent appear in the workspace because it's pinned, or because its own facets match the workspace's filter (e.g., an agent tagged `concern=financials` auto-appears in any workspace with that concern)? Pinning is explicit; facet-matching is emergent. Probably both — pinning overrides matching.
- **Terminology.** "Workspace" is SwiftUI-overloaded (the scene builder uses it). "View" is too generic. "Board" / "Pane" / "Desk" all carry baggage. Worth locking in before it shows up in user-facing strings.
- **Migration from today's flat vault.** Every existing conversation lands in a default workspace with no facets? Gets auto-tagged by heuristics? User-assisted backfill on first launch? Important because this is user data — a bad migration is a bad day.
