# Wiki — design doc

A human-curated, agent-readable knowledge layer that lives alongside conversations and the RAG corpus. Working document; nothing here is committed code yet. The aim is to identify the smallest shape that fits the existing primitives (workspaces, vault, RAG, tools) without inventing parallel storage or a parallel editor.

---

## Why a wiki, given what already exists

The app currently has three places where knowledge accretes, none of which is a wiki:

1. **Conversations** (vault, GRDB, FTS5). Linear, append-only, scoped to a session. Searchable but not curated. A useful answer in turn 12 of a 30-turn chat is effectively lost.
2. **Workspace data folders** (RAG corpus). User-supplied input documents — the *sources*, not the user's own synthesis.
3. **Transcript exports** (Markdown / PDF / HTML). Snapshots, not living documents.

What's missing is a place for the user's *own*, durable, hand-edited notes — short pages they want to find by name, link between, and reference from chat. Three concrete pulls:

- **"What did I conclude last time?"** Today the answer is buried in a transcript or a vault search. A wiki page named "acme-q1-thesis" answers it in one click.
- **"Use this context whenever I'm in this workspace."** A workspace-scoped page like "house-style" or "company-glossary" is a more honest pin than re-pasting the same paragraph into every system prompt.
- **Agents that write, not just read.** `fs.write` exists but writes to `~/Documents` — the artifact is divorced from the workspace. A `wiki.write` tool gives the research-assistant agent a place to leave a one-page summary the user will actually find later.

The wiki is the "things I'd otherwise paste into Notes.app, but want the model to see" layer.

---

## Design commitments

Locked in for the design phase, not up for re-litigation during implementation:

- **Scoping unit is the workspace.** A wiki belongs to a workspace, the same way the RAG corpus does. No global wiki in MVP. The "Default" workspace gets one too — users without a workspace concept still benefit.
- **Pages are Markdown text, full stop.** Same flavour as transcripts (KaTeX + highlight.js already bundled). No rich-text WYSIWYG, no blocks, no databases. A page is a `String` with a title.
- **Storage in the vault, not the filesystem.** Pages live in `vault.sqlite` next to conversations. Reasons in [Storage](#storage). Filesystem-backed wikis (like Obsidian vaults) are an *export* concern, not the storage primitive.
- **Wikilinks are `[[Page Title]]`.** Standard CommonMark extensions punt on this; we resolve them at render time against the page table. Unresolved links render as red and offer "Create page" on click.
- **FTS over pages, indexed in the same FTS5 table family as conversations.** Search-as-you-type from the History tab gains a "Pages" section.
- **The wiki is a corpus the RAG pipeline can read.** Pages are indexable as RAG sources; an agent answering a workspace question pulls from both the data folder and the wiki. See [RAG interaction](#rag-interaction).
- **Agents read and write pages through tools, not through the filesystem.** New tool family: `wiki.read`, `wiki.write`, `wiki.search`, `wiki.list`. Sandboxed by workspace.
- **No live multi-user collaboration.** This is a local app; the wiki is single-writer. Conflict resolution is out of scope.
- **Version history is a snapshot table, not git.** Every save writes a `page_revisions` row. Diff/restore UI deferred but the data is captured from day one — adding a revision after the fact would be impossible.

---

## Non-goals

Worth stating out loud so they don't creep in:

- **Block-based editing** (Notion, Logseq). Reaching for a block model means reaching for a custom rich-text engine; the value-to-cost ratio for a local chat app is poor.
- **Bidirectional sync to Obsidian / Bear / Logseq.** The export path lands flat Markdown files; importing back into the vault is a different feature and not part of MVP.
- **Wiki-as-website publishing.** Quarto already renders Markdown to HTML; if a user wants a static site, they render through Quarto, not through a wiki publishing pipeline.
- **Page templates / forms.** A page is a string. Convention over configuration.
- **Permissions / ACLs.** Single-user app.

---

## Storage

### Vault schema (migration `v6_wiki`)

```sql
CREATE TABLE wiki_pages (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id  INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    slug          TEXT    NOT NULL,            -- normalized form of title, lowercased, dashes
    title         TEXT    NOT NULL,            -- canonical display title
    body          TEXT    NOT NULL,            -- Markdown source
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL,
    UNIQUE (workspace_id, slug)
);

CREATE INDEX idx_wiki_pages_workspace_updated
    ON wiki_pages(workspace_id, updated_at DESC);

-- Revision history; one row per save.
CREATE TABLE wiki_page_revisions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    page_id     INTEGER NOT NULL REFERENCES wiki_pages(id) ON DELETE CASCADE,
    body        TEXT    NOT NULL,
    saved_at    INTEGER NOT NULL,
    saved_by    TEXT    NOT NULL              -- 'user' | 'agent:<agent-id>'
);

-- Adjacency for [[wikilinks]] — populated by the renderer/parser on save.
CREATE TABLE wiki_links (
    src_page_id  INTEGER NOT NULL REFERENCES wiki_pages(id) ON DELETE CASCADE,
    dst_slug     TEXT    NOT NULL,             -- targets a slug, not an id, so links survive renames + can dangle
    PRIMARY KEY (src_page_id, dst_slug)
);

CREATE INDEX idx_wiki_links_dst ON wiki_links(dst_slug);

-- FTS5 mirror, content-rowid linked. Same pattern as messages_fts.
CREATE VIRTUAL TABLE wiki_pages_fts USING fts5(
    title, body, content='wiki_pages', content_rowid='id', tokenize='porter unicode61'
);
-- Triggers to keep wiki_pages_fts in sync omitted here — same shape as messages_fts triggers.
```

Why vault over filesystem:

- **Atomic with conversations.** Searching "show me everything I have on Acme" should hit transcripts, agent traces, and pages in one query — they need to be in the same FTS instance.
- **Workspace cascade is automatic.** Deleting a workspace removes its pages; the existing `ON DELETE CASCADE` semantics carry over.
- **Backup story is unchanged.** Users already back up `vault.sqlite`; nothing new to remember.
- **Filesystem layout becomes an export concern**, not a storage choice. Users who want a folder of `.md` files can ask for one; the source of truth stays in SQLite.

### Slug normalization

`title → slug` is the same lowercase-dashes-strip-punctuation rule used by every static site generator. Done in Swift, deterministic, idempotent. Stored alongside the title rather than recomputed at query time so renames don't break search-by-slug. Renaming a page rewrites `slug`; backlinks (which reference `dst_slug` in `wiki_links`) need an explicit "Rename + update backlinks" action — without it they dangle, which the renderer flags but tolerates.

---

## Page format and wikilinks

A page is CommonMark plus two extensions:

- `[[Page Title]]` — internal link. Resolves against `wiki_pages.slug` for the active workspace. Rendering: green if resolved, red with a `+` affordance if not.
- `[[Page Title|display text]]` — labelled internal link. The display text shows; the slug resolves against the LHS.

Implementation: the existing Markdown renderer used in `ChatTranscript` already runs through a Swift Markdown pipeline — wikilinks get a pre-pass regex transformation before the CommonMark parse, replacing them with normal `[text](wiki://slug)` links. The chat-side renderer already knows how to handle custom URL schemes; `wiki://` taps the workspace's wiki store rather than `NSWorkspace.open`.

### Wikilink parsing on save

On every save, parse out the `[[...]]` references and rewrite the `wiki_links` table for that page in a single transaction. Cheap (regex over a string) and keeps the backlinks panel a constant-time lookup rather than a full-table scan.

---

## UI surface

Three entry points, ordered by frequency:

### 1. New sidebar tab: **Pages**

Adjacent to History / Voice / Tools / Agents. Shows:

- Search field (FTS5, scoped to active workspace, matches title and body).
- Recent pages list (most recently updated, paged).
- "New page" button at the top.

Click a page → opens the editor pane in the main content area, replacing the chat transcript view (same pattern as History opening a transcript). Cmd-clicking opens in a new window if multi-window workspaces ship.

### 2. Inline `[[...]]` autocomplete in the chat composer

Typing `[[` in the composer pops a small list of candidate pages from the active workspace. Selecting one inserts `[[Title]]` into the prompt. On send, the wikilink is resolved server-side: the page body is inlined into the prompt as a fenced block before the model sees it. Failure to resolve sends the literal `[[Title]]` through unchanged.

This is the primitive that makes the wiki *useful* in chat — it's how a user says "use this page as context for this turn" without copy-pasting.

### 3. The editor pane

Two-pane Markdown editor, classical:

- Left: source `TextEditor`, monospace, line numbers off.
- Right: live-rendered preview via the same Markdown pipeline used in transcripts.
- Toolbar: title field (renames the page), save button (debounced auto-save in the background, button is for explicit revisions), revision history disclosure, "Show backlinks" disclosure.

No WYSIWYG. The pane reuses `SplashCodeHighlighter` for fenced code blocks in the preview side.

### Backlinks disclosure

Below the editor: "Linked from N pages" → expand → list of pages whose `wiki_links.dst_slug` matches this page's slug. Click → navigate. Cheap query against `idx_wiki_links_dst`.

---

## Agent integration

A new tool family, gated by `requirements.toolsAllow` like every other tool:

| Tool | What it does | Sandbox |
|---|---|---|
| `wiki.list` | List page titles + slugs in the active workspace, optionally filtered by glob on title | Active workspace only; 200-entry cap |
| `wiki.read` | Read a page by slug → returns title + body | Active workspace only; 64 KB cap (matches `fs.read`) |
| `wiki.search` | FTS5 search of pages (title + body), top-K hits | Active workspace only; `topK` clamped 1–20 |
| `wiki.write` | Create or update a page (`slug`, `title`, `body`, `mode: create|overwrite|append`) | Active workspace only; 1 MB cap; revision row records `saved_by='agent:<id>'`; `mode=create` refuses to overwrite, `mode=append` adds a `\n\n---\n\n` separator |
| `wiki.delete` | Delete a page | Active workspace only; cascades to revisions and links via FK |

Notes:

- **No filesystem path argument.** The whole point is that the agent doesn't need to know where the wiki lives.
- **Workspace scope is implicit**, derived from the active `ChatViewModel.currentWorkspaceId` at tool-invocation time. Same pattern as `vault.search`.
- **`wiki.write` is destructive by default; the persona's system prompt should teach the agent to prefer `mode=append` for unattended writes.** The first agent that's allowed `wiki.write` should also have `wiki.read` so it can check before clobbering.
- **No `wiki.rename`** in MVP — renames are a UI-side action (which knows to update backlinks). An agent that wants to rename can `read → wiki.write(new) → wiki.delete(old)`, which is loud enough that it'll show up in the tool trace.

A natural bundled persona: a **"note-taker"** agent with `wiki.list`, `wiki.read`, `wiki.search`, `wiki.write` — system prompt teaches it to write a page summarizing the current chat when asked "save this as a note."

---

## Conversation → page promotion

A heavily-requested-by-the-author flow: "this turn was useful — promote it to a page."

UI: hover-action on any assistant turn (alongside Regenerate). "Save as page…" opens a small sheet with a pre-filled title (LLM-derived from the first sentence) and the assistant body as the page content. Save creates a row in `wiki_pages` and a revision in `wiki_page_revisions` with `saved_by='user'`.

Pre-fill heuristic: take the first 60 chars of the message, strip Markdown, smart-trim at the nearest word boundary. Cheap; user can edit before saving. No need to spin a model for title generation in MVP.

---

## RAG interaction

Two modes; the workspace settings sheet picks one (default: **augment**).

- **augment** (default): pages are an *additional* source kind for the RAG ingestor. `WorkspaceIngestor` gains a "ingest wiki pages" pass alongside the data-folder pass; pages get chunked and embedded the same way. A `kind='wiki'` value on the `sources` row distinguishes them. Re-ingest fires automatically on page save (single-page reingest is cheap — split, embed, upsert).
- **off**: the wiki is searchable in the UI but never injected into prompts via RAG. The user controls injection by writing `[[Page]]` in the composer.

The "augment" path is what most users want; the "off" path matters for users who want pages as a structured personal scratch-space without their model conditioning on them implicitly.

A subtle point: pages already exist in vault FTS, and the RAG pipeline already exposes `vault.search` to agents. There's a question of whether `wiki.search` should be a thin alias over `vault.search` filtered to wiki rows, or a separate FTS path. Lean: separate path. `vault.search` searches *messages*; users should be able to search the wiki without dragging unrelated transcript hits into the result set. Two FTS tables, two tools.

---

## Versioning

Every save (UI or `wiki.write`) inserts a `wiki_page_revisions` row. This is cheap for a local app and bounds well — 1 KB average page × 100 revisions × 50 pages = 5 MB. We keep all revisions in MVP; if storage becomes a real concern, a "trim revisions older than N days" maintenance task is a one-line query.

UI in MVP: a "History" disclosure on the editor pane shows a list of timestamps + author (`user` or `agent:<id>`) + first 80 chars of the body. Clicking a row pops a read-only viewer; "Restore" writes a new revision identical to the historical body (so restoring is itself a revision — no destructive rollback).

Diff view deferred. Three-way merge nonexistent (single-writer assumption).

---

## Phased plan

Pacing matches `rag-plan.md`'s phase structure. Estimated 7–10 focused days.

### Phase 1 — Schema + store (~1–2 days)

- Vault migration `v6_wiki`: tables, indexes, FTS, triggers.
- `WikiStore` actor: CRUD over `wiki_pages`, revision append on save, backlink rewrite on save, FTS sync via triggers (no manual sync code).
- Tests: migration up from a v5 vault preserves existing data; create/read/update/delete round-trip; FTS query returns hits; revision count increments per save; cascade on workspace delete.

### Phase 2 — UI: Pages tab + editor (~2–3 days)

- New `PagesSection` in the sidebar with search + recent + "New page".
- `WikiEditorView` two-pane editor. Reuses the existing Markdown render pipeline.
- Wikilink prepass (regex `[[...]]` → `[](wiki://slug)`) plumbed through the renderer.
- `wiki://` URL handler routes to `WikiEditorView` for the slug, falling back to a "Create page" prompt for unresolved slugs.
- Tests: snapshot tests on the renderer pre-pass; UI smoke that opening a page round-trips title + body.

### Phase 3 — Composer integration (~1 day)

- `[[` autocomplete in the composer (queries `wiki_pages` by title prefix in the active workspace).
- Resolution pass on send: replace `[[Page]]` with the page body as a fenced block, prefixed by a one-line "From wiki page: <title>" header, before the model sees the prompt.
- Test: composer with `[[foo]]` where `foo` exists produces an augmented send; where `foo` doesn't exist sends the literal text.

### Phase 4 — Agent tools (~1–2 days)

- `wiki.read`, `wiki.write`, `wiki.search`, `wiki.list`, `wiki.delete` registered alongside the existing builtin tool list.
- Workspace-scope binding: tool implementations resolve the workspace from a context object passed at tool-registration time (same pattern as `vault.search`).
- Bundled "Note-taker" agent JSON in `Resources/agents/`.
- Tests: write-then-read round-trip; FTS search returns the just-written page; `mode=create` refuses overwrite.

### Phase 5 — RAG augmentation (~1–2 days)

- `WorkspaceIngestor` gains a wiki pass. Source kind `wiki`, content hash on the body, re-ingest on page save.
- Workspace setting toggle (`wikiInRAG: Bool`, default `true`).
- Tests: saving a page triggers (mocked) ingestor invocation; toggling the setting off skips it.

### Phase 6 — Promotion + revision history UI (~1–2 days)

- Hover-action on assistant turns: "Save as page…" sheet.
- Editor pane revision-history disclosure with restore.
- Tests: promotion creates a page and a revision; restore appends a new revision matching the historical body.

---

## Open questions

Resolve before phase 2 (none are blocking phase 1):

- **Per-page workspace assignment vs. per-workspace pages.** I've assumed per-workspace (a page belongs to exactly one workspace). The alternative — a page that's visible in multiple workspaces — fits the facet-tagged future model in `workspaces.md` better but balloons the MVP. Lean: per-workspace; revisit when facets land.
- **Wikilink resolution across workspaces.** What does `[[Page]]` mean when the active workspace doesn't have it but another does? Lean: resolve only within the active workspace; offer "Create here" on miss. Cross-workspace search comes when facets land.
- **Default workspace getting a wiki.** I've said yes. The downside is users who never wanted RAG/workspaces also get "Pages" in their sidebar. Acceptable — the tab is empty until they create a page, and the cost is one row.
- **Conflict on simultaneous edits** (UI editor vs. `wiki.write` from a running agent). Last-write-wins is fine for local single-user; the revision table makes the lost write recoverable. Worth a one-line warning toast if `updated_at` advances between editor open and save? Possibly. Not blocking.
- **`wiki.write` and unattended agents.** A scheduled or long-running agent that writes pages on every turn could fill the revision table. Does `wiki.write` collapse no-op writes (body unchanged → no revision)? Lean: yes, on hash equality.
- **Export to a folder of `.md` files.** Useful for users who want to edit in another tool occasionally, or back up to git outside the vault. Defer; one-shot CLI command later.
- **Title clashes.** Two pages with different casing (`acme` vs. `Acme`) collapse to the same slug. Slug uniqueness enforces this; the UI should reject the second creation with "a page with this title already exists." Confirm the rename flow handles "tried to rename to an existing slug" cleanly.

---

## Deferred (explicitly not in MVP)

- Block editor / WYSIWYG.
- Diff view between revisions.
- Folder/`.md` export and re-import (round-trip).
- Static-site publishing via Quarto (Quarto can already render a folder of `.md`; the wrap is a separate doc).
- Cross-workspace pages / facet-scoped pages (waits on workspaces.md).
- Templates and per-page metadata (frontmatter parsing). Pages stay flat strings until there's a clear use case.
- Image/attachment embedding. Today the wiki body is text; images would need a sibling attachments table, which is RAG's deferred attachment work too. Don't open this front yet.
- Multi-user / sync. Out of scope for a local app.
