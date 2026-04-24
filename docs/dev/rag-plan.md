# RAG implementation plan

Per-workspace retrieval-augmented generation, ported from the validated `cyllama` Python implementation at `~/projects/personal/cyllama`. Ships in six phases, ~2 weeks of focused work. Includes a "workspace-lite" prerequisite because RAG is workspace-scoped.

**History note.** The original plan proposed vendoring `sqlite-vector` (Marco Bambini / SQLite AI) as a dynamic extension loaded via `sqlite3_load_extension`. A spike (since deleted — see git history for `Sources/SqliteVecSmoke/`) proved this unworkable under Apple's system SQLite — `sqlite3_enable_load_extension` is stripped from the TBD and `sqlite3_auto_extension` is a MISUSE-returning stub. Pivoted to `SQLiteVec` (jkrukowski, MIT), a Swift package that bundles its own SQLite amalgamation with `SQLITE_CORE` and statically links `sqlite-vec` (Alex Garcia, MIT). Works alongside GRDB's system-SQLite usage — they live in separate link-time worlds.

---

## Design commitments

Locked in, not up for debate during implementation:

- **Scoping unit is the workspace.** A workspace owns a corpus; all conversations in that workspace query it.
- **The workspace's corpus is a filesystem folder.** Users put files in the folder; the app ingests them. No separate "attach file to conversation" flow in MVP.
- **No global corpus.** No per-conversation corpus. One axis only.
- **Vector backend: `SQLiteVec`** (https://github.com/jkrukowski/SQLiteVec, MIT). Bundles sqlite-vec statically into its own SQLite. `vec0` virtual tables with cosine distance. Required swift-tools-version 6.1 (already bumped).
- **Two-DB architecture.** Main vault (`vault.sqlite`, GRDB + Apple system SQLite) holds conversations, messages, workspaces, agents, tags. Vector store (`vectors.sqlite`, SQLiteVec's bundled SQLite) holds sources, chunks, embeddings. Joined at the app layer by `workspace_id` and `chunk.id` ↔ `vec_items.rowid`.
- **Embedding model: `bge-small-en-v1.5.gguf`** (130 MB, 384 dimensions, cosine). Runs via llama.cpp embedding mode in a dedicated `EmbeddingRunner` actor separate from the chat `LlamaRunner`. Swappable later.
- **Source formats in MVP: `.txt`, `.md`, `.json`.** PDF deferred (Apple PDFKit text extraction is serviceable but quality varies; ship behind a flag in v2).
- **Ingestion: on-demand scan, not watcher-based.** A "Scan folder" action in the workspace UI. FSEvents watcher deferred.
- **No quantization in MVP.** `vec0`'s default flat scan handles tens of thousands of chunks in single-digit milliseconds. Move to quantized indexes only when measured latency demands it.
- **Manual mean-pool + L2-normalize on the Swift side.** Never delegate pooling to llama.cpp (`cyllama` discovered this the hard way; `embedder.py:204` has the TODO).
- **Hard-fail on metadata mismatch.** Dimension, metric, and model identity are stamped in the vector DB on first ingest; mismatches on reopen produce a clear error with fix hints. No silent index corruption.

---

## Phase 0 — Workspace-lite (prerequisite, ~2–3 days)

RAG needs a scoping container. Rather than block on the full workspace refactor (see `docs/dev/workspaces.md`), we ship a minimal subset: name + data folder + conversation linkage. The full refactor extends this; nothing is discarded.

### 0.1 Schema (vault migration `v4_workspaces`)

```sql
CREATE TABLE workspaces (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    data_folder TEXT,                -- absolute path; NULL means "no corpus yet"
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

-- Add nullable FK to conversations; default-workspace backfill below.
ALTER TABLE conversations ADD COLUMN workspace_id INTEGER
    REFERENCES workspaces(id) ON DELETE SET NULL;

CREATE INDEX idx_conversations_workspace
    ON conversations(workspace_id, updated_at DESC);
```

On migration: create one `workspace` row named "Default" with `data_folder = NULL`, assign `workspace_id` of every existing conversation to it. Nobody loses data; everyone gets a workspace.

### 0.2 Vault API

- `createWorkspace(name:, dataFolder:) -> Int64`
- `renameWorkspace(id:, name:)`
- `setDataFolder(id:, path:)`
- `deleteWorkspace(id:)` — cascades to sources/chunks/embeddings (see phase 3); conversations get `workspace_id = NULL` so they survive. Alert the user.
- `listWorkspaces() -> [WorkspaceSummary]`
- `setConversationWorkspace(conversationId:, workspaceId:)`

### 0.3 UI

- **Header workspace switcher.** Adjacent to the existing agent picker in `ChatHeader`. Menu lists workspaces, with a checkmark on the active one. "Manage workspaces…" at the bottom opens a sheet. New conversations inherit the active workspace; the `workspace_id` FK is set on `startConversation`.
- **Workspaces sheet.** Minimal CRUD: list + name field + folder picker + delete with confirmation. Follows the `AgentInspectorView` sheet pattern.
- **Active workspace persisted** to `UserDefaults` via `PersistKey.activeWorkspaceId`.
- **`ChatViewModel.currentWorkspaceId`** threaded through everywhere a conversation is created.

### 0.4 Tests

- Migration: starting from a v3 vault, v4 creates the Default workspace and assigns every existing conversation to it.
- `setDataFolder` normalizes/validates the path (expands `~`, rejects non-directories).

---

## Phase 1 — SQLiteVec integration (~2 hours)

Drastically simpler than the original plan because SQLiteVec is a pure Swift Package dependency with no CMake, no fetch script, no bundled dylib copying.

### 1.1 Package dependency (done in the spike)

Already in `Package.swift`:
```swift
.package(url: "https://github.com/jkrukowski/SQLiteVec", from: "0.0.9"),
```
The `Infer` executable target gains `.product(name: "SQLiteVec", package: "SQLiteVec")`.

### 1.2 Early init

Call `try SQLiteVec.initialize()` once, as early as possible — `AppDelegate.applicationDidFinishLaunching` is the natural spot. This registers `sqlite-vec`'s init function with the bundled SQLite's auto-extension table; every subsequent `Database(...)` open gets `vec0` and friends installed automatically.

### 1.3 `VectorStore` actor wraps SQLiteVec

A single `Database` instance per app (pointing at `~/Library/Application Support/Infer/vectors.sqlite`), wrapped in an actor so the call sites don't mix the two DBs. Lifetime parallels `VaultStore`: shared instance, `shutdown()` call from `AppDelegate.applicationWillTerminate`.

### 1.4 Smoke test

Was provided by the `Sources/SqliteVecSmoke/` spike (since deleted). Validated: `SQLiteVec.initialize()` registers the `vec0` extension; `Database(.uri(...))` opens with the vec0 virtual table available; insertions with `[Float]` vectors round-trip; KNN via `MATCH ?` returns hits in ascending-distance order; GRDB (using Apple's system SQLite) coexists with SQLiteVec (bundled SQLite) in the same binary.

---

## Phase 2 — EmbeddingRunner actor (~2–3 days)

New actor parallel to `LlamaRunner` / `MLXRunner`. Distinct actor so the embedding model stays loaded independently of the chat model.

### 2.1 Responsibilities

- `load(modelPath: String) async throws` — loads a GGUF embedding model via the existing llama.cpp framework. Pooling type set to `LLAMA_POOLING_TYPE_NONE` (we pool ourselves).
- `embed(_ text: String) async throws -> [Float]` — tokenize, encode, mean-pool across token hidden states, L2-normalize.
- `embedBatch(_ texts: [String]) async throws -> [[Float]]` — sequential for MVP (llama.cpp embedding mode doesn't batch cleanly under single-context), exposed as batch API so callers don't have to loop.
- `dimension: Int` — exposed after load, used by `VectorStore` for its compatibility check.
- `shutdown()` — frees the llama context; called from `AppDelegate.applicationWillTerminate`.

### 2.2 Concurrency

Non-blocking lock pattern from `cyllama/embedder.py:235`: concurrent calls throw rather than queue. Prevents KV-cache corruption from interleaved decodes in the C++ layer. Callers serialize via the actor boundary naturally.

### 2.3 Mean-pool + L2-normalize

Port from `cyllama/embedder.py`. Use `Accelerate.vDSP` for the reductions and normalization — the math is trivial but the Accelerate path is ~5× faster than a Swift loop on modern macs.

### 2.4 Model discovery

- New `PersistKey.embeddingModelPath`.
- Default to looking for `bge-small-en-v1.5-q8_0.gguf` in the existing GGUF directory (same as chat models).
- If not present, the workspace's "Scan folder" action errors with a clear "download bge-small-en-v1.5.gguf to `<path>`" message. Auto-download deferred — don't want silent 130 MB fetches.

### 2.5 Tests

- Unit test with a known-good small embedding model (fixture) asserting:
  - Dimension matches.
  - `embed("hello")` is L2-normalized (norm ≈ 1.0).
  - Same input → bit-identical output (deterministic).
  - Different inputs → cosine similarity in a plausible range.

---

## Phase 3 — VectorStore actor (~1–2 days)

Actor wrapping SQLiteVec's `Database`. Separate file (`vectors.sqlite`) from the main vault. Swift-native API; callers never see `vec0` SQL.

### 3.1 Schema (bootstrap-at-init, not migrated alongside the vault)

`VectorStore` creates its tables on first open. Simpler than a migration chain — this DB is derived data; if its schema changes breakingly, we can regenerate by re-ingesting from the workspace folders. No user content here that isn't recoverable.

```sql
-- Per-workspace metadata so reopens verify dimension/metric/model.
CREATE TABLE IF NOT EXISTS workspace_meta (
    workspace_id INTEGER PRIMARY KEY,
    embedding_model TEXT NOT NULL,
    dimension INTEGER NOT NULL,
    metric TEXT NOT NULL DEFAULT 'cosine',
    chunk_size INTEGER NOT NULL,
    chunk_overlap INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);

-- Source = one file ingested from a workspace's folder.
CREATE TABLE IF NOT EXISTS sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id INTEGER NOT NULL,
    uri TEXT NOT NULL,                   -- absolute path
    content_hash TEXT NOT NULL,          -- MD5 of raw file bytes, for dedup
    kind TEXT NOT NULL,                  -- 'txt' | 'md' | 'json'
    ingested_at INTEGER NOT NULL,
    meta TEXT                            -- JSON, freeform
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_dedup
    ON sources(workspace_id, content_hash);

-- Chunks = text segments of a source, in order.
CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER NOT NULL,
    ord INTEGER NOT NULL,
    content TEXT NOT NULL,
    offset_start INTEGER NOT NULL,
    offset_end INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chunks_source ON chunks(source_id, ord);

-- sqlite-vec virtual table. `rowid` is shared with chunks.id.
CREATE VIRTUAL TABLE IF NOT EXISTS vec_items USING vec0(
    embedding float[384] distance=cosine
);
```

Foreign-key cascades aren't expressed in the schema because sqlite-vec's virtual tables don't play nicely with FK constraints on regular tables; cascades are handled in app code (delete chunks → delete corresponding `vec_items` rowids → delete source row).

The `384` in the `vec0` declaration is a baked constant matching the bge-small embedding dimension. If the user later swaps to a different model, the table has to be dropped and rebuilt — this is recorded in `workspace_meta` and enforced by the compatibility check.

### 3.2 API

- `ensureInitialized(workspaceId:, model:, dimension:, chunkSize:, chunkOverlap:) async throws` — upserts `workspace_meta` on first ingest; hard-fails on mismatch with a user-facing error ("the vector store for this workspace was built with X; current app is configured for Y").
- `ingest(workspaceId:, uri:, contentHash:, kind:, meta:, chunks: [(content, offsetStart, offsetEnd, embedding)]) async throws -> SourceID` — inserts source row, chunk rows, and `vec_items` rows in one transaction. Idempotent on `(workspace_id, content_hash)` — repeat ingest returns the existing id without duplicating.
- `deleteSource(id:) async throws` — deletes chunks + their `vec_items` by rowid + the source row.
- `search(workspaceId:, queryEmbedding: [Float], k: Int, sourceFilter: [SourceID]?) async throws -> [SearchHit]` — `SELECT chunks.content, sources.uri, chunks.ord, distance FROM vec_items JOIN chunks ON chunks.id = vec_items.rowid JOIN sources ON sources.id = chunks.source_id WHERE sources.workspace_id = ? AND vec_items.embedding MATCH ? ORDER BY distance LIMIT ?`.
- `listSources(workspaceId:) async throws -> [SourceSummary]` — for the sources panel.
- `sourceStatistics(workspaceId:) async throws -> (sources: Int, chunks: Int, bytes: Int64)` — badge in the workspace UI.

### 3.3 Tests

- Bootstrap: opening a fresh `vectors.sqlite` creates the expected tables.
- Ingest + search round-trip with synthetic 384-d vectors (no embedding model needed for this test — we mock).
- Dedup: ingesting the same `content_hash` twice is a no-op (returns existing id).
- Compatibility check: mismatched dimension on `ensureInitialized` throws a specific error.
- `deleteSource` cascades: chunks gone, `vec_items` entries gone, search no longer returns the content.

---

## Phase 4 — Ingestion pipeline (~1–2 days)

### 4.1 `TextSplitter`

Port `cyllama/splitter.py`'s recursive character splitter. Hierarchical separators: `\n\n`, `\n`, `. `, word boundary, character. Chunk size 512 chars, overlap 50 chars (defaults — both configurable). `MarkdownSplitter` (structure-aware) stubbed as future work; `.md` files use the generic splitter in MVP.

### 4.2 Loaders

- `TextLoader` — `String(contentsOf: url, encoding: .utf8)`.
- `MarkdownLoader` — same; metadata tags the source kind as `markdown`.
- `JSONLoader` — pretty-prints the decoded JSON to text.
- No PDF in MVP.

### 4.3 `WorkspaceIngestor`

Orchestrates:
1. Scan `workspace.data_folder` recursively for files matching supported extensions.
2. For each file, compute MD5 of raw bytes.
3. Skip if `(workspaceId, content_hash)` already in `sources`.
4. Load content, split into chunks.
5. Call `EmbeddingRunner.embedBatch` for the chunk texts.
6. Call `VectorStore.ingest` with the bundle.
7. Report progress via a published `@Observable` state (files processed / total, current file name).

Sequential ingestion for MVP (one file at a time). Parallelization deferred.

### 4.4 UI surface

- Workspace management sheet gains a "Scan folder" button and a progress view.
- Errors per file surface in the `LogCenter` console (source: `rag`) rather than modal alerts — broken files shouldn't interrupt a batch.

### 4.5 Tests

- Ingest 3 synthetic .md files from a tmp dir into a fresh workspace; assert source count, chunk count, dedup on re-scan.

---

## Phase 5 — Query pipeline + chat integration (~2–3 days)

### 5.1 `RAGPipeline`

On every user turn in a workspace with a non-empty corpus:
1. Embed the user's message via `EmbeddingRunner`.
2. `VectorStore.search(workspaceId:, query:, k: 5)` — top 5 hits.
3. Score threshold (default 0.3 cosine) — drop weak matches so an irrelevant corpus doesn't inject noise.
4. If nothing survives: fall through to the normal chat path; no injection.
5. Format retrieved chunks into a prompt prefix (cyllama's template, lightly adapted):

   ```
   Use the following context to answer the question. If the context doesn't contain relevant information, say so.

   Context:
   <chunk 1>

   <chunk 2>

   ...
   ```

6. Prepend to the user message (not the system prompt — agent personas own the system prompt; RAG sits on top).
7. Pass the augmented message through the existing `sendUserMessage` path unchanged.

### 5.2 Citations in the transcript

Analogous to `StepTraceDisclosure`: each assistant reply with RAG context renders a collapsed "Sources" disclosure showing which chunks were used, their scores, and the source filename. Click a source → reveal file in Finder.

New field on `ChatMessage`: `retrievedChunks: [RetrievedChunkRef]?`. Persisted in the vault alongside `steps`.

### 5.3 Per-workspace toggle

A workspace-level setting `ragEnabled: Bool` (default `true` when a data folder is set). Turning it off is per-workspace, not per-conversation — simpler UX, matches the scoping model.

### 5.4 Tests

- Mock the embedder and store; assert that a user turn in a workspace with matching chunks produces an augmented prompt.
- Assert that empty/below-threshold results leave the prompt untouched.
- Assert that `ragEnabled=false` bypasses the pipeline entirely.

---

## Phase 6 — Deferred (explicitly not in MVP)

Listed so they don't accidentally creep in:

- **PDF ingestion.** Apple PDFKit works; quality varies on scanned docs. Ship behind a flag after MVP lands.
- **File watcher / auto-reingest.** FSEvents is finicky; manual "Scan folder" is fine until users complain.
- **Quantization.** `vector_quantize` + `vector_quantize_scan`. Earn when a corpus exceeds ~20k chunks.
- **Reranking.** Cross-encoder rerank of top-N. Measurable quality win but adds another model dependency.
- **Hybrid retrieval.** FTS5 + vector search union (cyllama's `HybridStore`). Often improves quality on short keyword queries.
- **Cross-workspace queries.** Not possible by design in MVP. If users want it later, requires revisiting the scoping model.
- **Image generation.** Separate plan; depends on durable attachments, which this plan doesn't build (RAG uses the workspace folder directly).
- **Streaming think-block stripping.** `cyllama/pipeline.py:72-125` handles Qwen3 / DeepSeek-R1 `<think>…</think>` blocks. Port if those models become common in the app.

---

## Cross-cutting

### Testing

- **Unit tests**: splitter behavior, mean-pool + L2-normalize math, tag normalization (already have), dedup invariants, migration up/down.
- **Integration test** (manual, not CI): load bge-small, ingest 10 Markdown files, run five queries, eyeball that top hits are semantically relevant.
- **Smoke test for sqlite-vector dylib loading**: separate XCTest scheme that depends on the bundled dylib (not part of `swift test`, which skips the xcframework-dependent bits).

### Logging

Every phase logs to `LogCenter` under source `rag`:
- Model loads + dimension.
- Ingest progress (file started / chunks produced / embedded / stored / failed).
- Query hits count + best score.
- Any hard-fail path (compatibility mismatch, missing model, corrupt file).

### Persistence-compatibility

- `ChatMessage.retrievedChunks` is a new optional field. Pre-existing transcripts render with it nil, no migration of `steps` needed.
- `workspace_id` on conversations is nullable; conversations created before v4 backfill to the Default workspace. No data loss.

### Migration safety

- Run the full migration chain (v1→v5) against a copy of the user's real vault on a dev machine before shipping. Back it up.
- Test specifically: deleting a workspace leaves conversations alive (their `workspace_id` nulls out) but removes all sources/chunks/embeddings. Alert the user in the UI.

### Estimated effort

| Phase | Scope | Days |
|---|---|---|
| 0 | Workspace-lite | 2–3 |
| 1 | SQLiteVec integration | ~0 (done in the spike) |
| 2 | EmbeddingRunner | 2–3 |
| 3 | VectorStore | 1–2 |
| 4 | Ingestion pipeline | 1–2 |
| 5 | Query pipeline + UI | 2–3 |
| **Total** | | **8–13** |

Call it **~2 weeks** at focused working pace. The SQLiteVec pivot saved ~2 days of dylib/CMake/bundle-copy work.

---

## Open questions

Resolve before starting phase 1 (most are low-stakes):

- **Workspace switcher location.** Header next to the agent picker (my default), or a dedicated title-bar element? Header is minimum-disruption; title-bar is more discoverable for a cross-cutting concept.
- **Does the Default workspace expose a data folder?** I'd say no — Default is for users who don't care about RAG. They can set a folder on it if they want.
- **Error surfacing for missing embedding model.** Alert dialog on first scan attempt, or a banner in the workspace management sheet? Banner is less interruptive.
- **Cascade semantics on workspace delete.** Source/chunk/embedding rows cascade — obvious. Conversations: currently set-null (orphaned). Alternative: reassign to Default. My lean: set-null + surface in a "Conversations with no workspace" section of the History tab, so users can rehome them.
- **Sources panel placement.** Inside the workspace management sheet (consistent), or a dedicated Sidebar tab (discoverable)? Probably the sheet for MVP; a sidebar tab if the corpus grows.
