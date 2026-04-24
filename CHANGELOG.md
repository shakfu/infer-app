# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.6]

### Added

- **Reasoning-model think-block handling.** Qwen3 / DeepSeek-R1 style `<think>…</think>` blocks are now rendered as a collapsed-by-default "Thoughts" disclosure above the assistant reply instead of leaking into the visible body as raw tag soup. `InferCore/ThinkBlockStreamFilter.swift` is a stateful stream filter that splits streaming pieces into `think` vs `reply` fragments and tolerates tags straddling piece boundaries (tag-start can arrive in one piece, tag-end in a later one). The transcript stores the two fragments side by side on `ChatMessage` and `ThinkingDisclosure` renders them with the same styling idiom as `StepTraceDisclosure`. Collapsed by default on every load — reasoning verbosity is interesting once, noise afterwards.

- **Thinking budget setting (`InferSettings.thinkingBudget`, default 4096).** Reasoning models decode both the `<think>…</think>` pass and the final answer; capping at `maxTokens` often exhausts the cap inside the think block and leaves nothing for the reply. The runner cap is now `maxTokens + thinkingBudget` — `maxTokens` stays the hard cap on *net* rendered tokens, `thinkingBudget` is the invisible decode allowance. Surfaced as a slider in the Parameters sidebar with guidance; persisted under `PersistKey.thinkingBudget`. For non-reasoning models the extra budget is harmless — they never emit think blocks so the net cap fires first.

- **Net-token accounting + KV compaction.** The generation loop now tracks net (rendered) tokens separately from total decoded tokens, and `requestStopCurrentRunner` fires when net reaches `maxTokens` even if the model is still inside a think block. After a turn that emitted thinking, `compactKVForVisibleHistory` clears the llama KV cache and re-submits the visible-only transcript, so think tokens don't eat context on subsequent turns. Header stats split when they diverge: `123 net · 456 gen · 45.2 tok/s`; identical counts collapse back to the compact single form.

- **Release-configuration Makefile targets.** `make build-release`, `make bundle-release`, `make run-release` recursively invoke the corresponding target with `INFER_CONFIG=Release`. Debug stays the default for active development (fast incremental builds, full debug symbols); Release is for perf testing, distribution dry-runs, or diagnosing "feels slower than it should" regressions against the optimized build. One set of rules, two configurations — no logic duplication.

- **Hybrid retrieval (vector + FTS5).** Dense embedding alone misses chunks whose answer vocabulary doesn't overlap with the query (e.g. a query for "vector database" against a corpus that uses the proper noun "SQLiteVec"). The vector store now keeps an FTS5 index over `chunks.content` (`content='chunks', content_rowid='id'` — same external-content pattern the vault uses on messages, with `unicode61 remove_diacritics 2` tokenizer). Triggers keep the index in sync on insert/update/delete; a one-shot backfill at bootstrap covers chunks ingested before hybrid existed. `VectorStore.search` runs both retrievers in parallel and fuses via Reciprocal Rank Fusion (k=60, equal weights) — chunks appearing in both retrievers' top lists rise above chunks appearing in only one. FTS-only hits get a real cosine distance via a `vec_distance_cosine(stored_embedding, query_embedding)` subquery so the UI similarity display stays consistent across retrievers. Per-search diagnostics on `VectorStore.lastSearchDiagnostics` (`vectorHits`, `ftsHits`, `ftsQuery`, `ftsError`, `usedFusion`); the Console tag `[hybrid: 30v+30f]` / `[vector-only: fts returned 0 for '...']` / `[fts error: ...]` makes it obvious which retriever contributed on each turn. Sanitizer is OR-joined and tokenizer-mirrored — splits the query on anything non-alphanumeric (matching `unicode61`'s tokenization of stored content), drops single-character tokens, phrase-quotes each term against FTS5 reserved-word collisions, joins with `OR` so BM25 can rank by partial matches rather than requiring every term in every chunk. 11 new unit tests cover the RRF fusion logic + sanitizer behaviour.

- **HyDE query reformulation (per-workspace, opt-in).** Before retrieval, the chat model generates a hypothetical passage answering the user's question, and *that* hypothetical is embedded for dense retrieval (FTS still uses the original query — keyword search benefits from the user's actual terms). Bridges vocabulary gaps when query phrasing diverges from source phrasing. New `generateOneShot(prompt:maxTokens:)` method on both runners isolates the side-channel call from the main conversation: `LlamaRunner` lazy-initializes a secondary llama context (separate KV cache, low-temperature sampler) so the user's chat state isn't disturbed; `MLXRunner` instantiates a fresh `ChatSession` with empty history. Per-workspace toggle stored in `UserDefaults` under `infer.workspace.<id>.hydeEnabled`; off by default since HyDE's quality ceiling is the chat model's knowledge of the corpus domain — for specialized corpora the chat model only knows at summary level (e.g. a long novel + small quantized chat model), the hypothetical can hallucinate and *misdirect* retrieval. Console tag `[hyde]` confirms when the path fired; the hypothetical itself is logged at debug level (source `rag`) so users can inspect what the model produced.

- **Cross-encoder reranking (per-workspace, opt-in).** When enabled on a workspace, hybrid retrieval over-fetches to 30 candidates and a `bge-reranker-v2-m3` cross-encoder re-scores each (query, chunk) pair, returning the top 5 by reranker score. Catches "topical-but-not-answerful" chunks the dense+FTS fusion couldn't separate. New `RerankerRunner` actor parallels `EmbeddingRunner` — same llama.cpp context pattern but configured with `LLAMA_POOLING_TYPE_RANK`, reads concatenated `[BOS] query [SEP] doc [SEP]` token streams, gets a single relevance logit per pair via `llama_get_embeddings_seq(ctx, 0)[0]`. Sequential under the hood (~1–2s for 30 pairs on M-series); batching deferred. New `RerankerModelRef` enum pins `gpustack/bge-reranker-v2-m3-GGUF` / `bge-reranker-v2-m3-Q8_0.gguf` (~315 MB), downloaded on demand through the same Hugging Face flow as the embedder with a missing-model banner in the workspace sheet. Console tag `[rerank: top5 of 30 in Ts, best=X.XX]` reports time + the reranker's top score (raw logit; positive = relevant, negative = not — useful diagnostic when the reranker's "best" is highly negative, indicating none of the candidates strongly answer the query). Toggle is disabled in the UI until the model is downloaded; the download banner shows even with the toggle off so users have a discoverable path to enable the feature.

- **Per-workspace settings infrastructure** (`PersistKey.workspaceKey(id:setting:)` + `PersistKey.WorkspaceSetting`). UserDefaults-backed key shape `infer.workspace.<id>.<setting>` so new per-workspace toggles can be added without a vault schema change. Two settings ship: `hydeEnabled`, `rerankEnabled`. Surfaced in the workspace sheet's new "Retrieval quality" section with one-line descriptions of each toggle's latency trade-off.

- **Console-side observability for the RAG pipeline.** Every retrieval-related path logs structured events under sources `rag`, `embedding`, `rerank`, `workspaces`. Per-file scan progress at debug level (`ingested X (N chunks)`) so users at the debug filter can verify nothing silently dropped; explicit terminal `scan successful` vs. `scan completed with warnings` line so success isn't ambiguous. Empty-chunks skip (rare — file contains only separator characters) now logs a warning instead of being a silent skip. `RAG.initialize()` happens in `applicationDidFinishLaunching` and the FTS index health check (`chunks=N, chunks_fts=M`) runs at VM init so a backfill mismatch is visible immediately.

- **Context-window percentage in the chat header (llama only).** Compact `42%` indicator next to the per-generation tok/s readout; tints orange past 80%, red past 95%. Tooltip carries raw `Context: used / total tokens used`. Renders only when the backend exposes a real context size — llama via `llama_n_ctx`; MLX doesn't expose `max_position_embeddings` from the loaded `ModelContainer`, so the indicator stays absent there (consistent with the rest of the MLX header). Header progress-bar widget removed at the same time — too crowded; the percentage carries the signal more compactly.

- **`docs/patches/sqlitevec.md`** documenting the four local patches against the vendored SQLiteVec (sqlite3ext.h move, macOS platform bump, Database.execute error-handle plumbing, Int64 binding case + Int narrowing fix). Each patch entry has root cause, one-line diff, and a re-apply snippet for when the vendored copy is bumped.

### Changed

- **Bundle output grouped by config.** `make bundle` writes to `build/Debug/Infer.app`; `make bundle-release` writes to `build/Release/Infer.app`. Both bundles share the same `.app` filename so Finder / Spotlight / Dock behave identically for either; switching configs doesn't force a rebuild of the other side. `INFER_APP_BUNDLE := $(BUILD_DIR)/$(INFER_CONFIG)/Infer.app` threads the config through bundle / run. Replaces the single `build/Infer.app` path.

- **Makefile target names dropped the `-infer` suffix.** `build-infer` → `build`, `bundle-infer` → `bundle`, `run-infer` → `run`. The suffix was a holdover from when this repo hosted multiple demo projects; with Infer the only app, the shorter names are unambiguous. Old names no longer resolve — update any aliases or scripts.

- **Header token-rate readout renames `visible` to `net`.** Matches the `InferSettings` field naming (net tokens = rendered reply; gen tokens = total decoded including stripped think content). Tooltip updated to call out that reasoning models emit `<think>…</think>` blocks that count against decode time and the context window but are hidden from the reply.

- **`LlamaRunner` main context `n_batch` raised 512 → 2048.** Longer prefills — especially after KV compaction re-submits the whole visible transcript — now fit in far fewer batch calls. `setHistory` still chunks defensively (see Fixed).

- **`maybeRunToolLoop`'s tool-call diagnostic message** now includes per-file ingest debug lines and a final success/warnings assertion. Earlier the only feedback was a count summary that could blend in with other events; the explicit `scan successful: N file(s) ingested in Ts` (or `scan completed with warnings`) line is unambiguous as a terminal state.

- **FTS5 sanitizer rule** changed from AND-joined phrase quotes to OR-joined token quotes, mirroring the unicode61 tokenizer's split rules so query tokens align with stored tokens. Previous AND behaviour returned zero hits on natural-language queries against narrative corpora because no single chunk contained every query term; the OR + BM25 fallback now ranks by partial overlap.

- **Workspaces as an organizational container.** New `workspaces` table in the vault (`v4_workspaces` migration) with a nullable `conversations.workspace_id` FK (`ON DELETE SET NULL` so conversations survive their workspace's deletion as orphans visible in the History tab). The migration creates a "Default" workspace and backfills every existing conversation into it — no data motion visible to users. New header picker (`ChatView/WorkspacePickerMenu.swift`) sits between the status view and the agent picker, showing the active workspace name plus a folder badge when a data folder is configured. Menu lists all workspaces with checkmark on active, plus "New workspace…" and "Manage workspaces…". Active workspace persisted to `UserDefaults` via `PersistKey.activeWorkspaceId`. Dual-purpose management sheet (`ChatView/WorkspaceSheet.swift`) handles both create and edit: name + data folder picker, stats, a compact list of all workspaces for quick-switching, and delete with confirmation (Default workspace can't be deleted). New conversations inherit the active workspace via `activeWorkspaceId` threaded into `startConversation`. Deliberately minimal — this is "workspace-lite" so RAG has a scoping unit to live on; full window management / pinned agents / facets (per `docs/dev/workspaces.md`) extend this schema rather than replacing it.

- **Retrieval-augmented generation (RAG), per-workspace.** A workspace's data folder becomes its corpus: files in `.txt` / `.md` / `.json` get ingested into a dedicated vector store, and every chat in that workspace augments user turns with retrieved context before generation. End-to-end flow in six composable pieces:
  - **Vector store** (`InferRAG` target, new library): actor over [`SQLiteVec`](https://github.com/jkrukowski/SQLiteVec) backed by a separate `vectors.sqlite` file. `ensureInitialized` stamps per-workspace metadata (embedding model, dimension, metric, chunk size/overlap) and hard-fails on mismatch to prevent silent index corruption. `ingest` is transactional and idempotent on `(workspace_id, content_hash)`. `search` runs KNN via the `vec0` virtual table scoped to the workspace. `deleteWorkspaceData` cascades manually across `sources` → `chunks` → `vec_items` since sqlite-vec virtual tables don't participate in FK chains. Dimension is baked into the `vec0 float[384] distance=cosine` declaration to match bge-small.
  - **Embedding runner** (`Infer/EmbeddingRunner.swift`): dedicated llama.cpp context configured for embedding (`LLAMA_POOLING_TYPE_NONE`, `embeddings = true`, encoder mode), running a GGUF embedding model independently of the chat `LlamaRunner`/`MLXRunner` so the model stays resident across queries. Mean-pool + L2-normalize on the Swift side via `Accelerate.vDSP` — per the cyllama port's experience, llama.cpp's internal pooling is unreliable across model families. Non-blocking busy flag rejects concurrent re-entry. `llama_memory_clear` between calls so sequential embeds don't leak KV state.
  - **Embedding model discovery + Hugging Face download** (`Infer/EmbeddingModel.swift`): single `EmbeddingModelRef` enum pins the default (`CompendiumLabs/bge-small-en-v1.5-gguf`, `bge-small-en-v1.5-q8_0.gguf`, 384 dim, ~130 MB). Model lands in the same GGUF directory as chat models. Missing-model banner in the workspace sheet offers a one-click download via `HubClient.downloadFile` with progress routed through `Progress` KVO → `vm.embeddingModelDownloadProgress` → an inline progress bar. No launch-time nag — the download only appears once a user engages with a RAG-enabled workflow.
  - **Text splitter** (`InferRAG/TextSplitter.swift`): recursive character splitter ported from cyllama. Hierarchical separators (`\n\n` → `\n` → `. ` → ` ` → hard split), configurable size/overlap (defaults 512/50), grapheme-accurate offsets preserved for citation UI, merge phase seeds each new chunk with the tail of the previous for character-level overlap. 12 unit tests cover paragraphs, sentences, hard-split fallback, overlap invariant, Unicode/emoji, monotonic offsets, size ceilings.
  - **Ingestion orchestrator** (`Infer/ChatViewModel/Ingest.swift`): `scanAndIngest(workspaceId:)` enumerates the data folder recursively (skipping hidden files and package contents), hashes each file via MD5 for dedup, loads (`SourceLoader` in `RAGLoaders.swift` — UTF-8 `.txt`/`.md`/`.json`, rejects empty files), splits into chunks, embeds each chunk sequentially, and stores transactionally. Live progress published on `vm.ingestProgress` with `(totalFiles, processedFiles, currentFile, ingested, skippedDuplicates, failed)`; workspace sheet renders a progress bar + current file + per-counter split while running, and a corpus stats line (`N sources, M chunks`) when idle. Per-file failures are warnings in `LogCenter`; only catastrophic failures (embedder load, vector store init) abort the scan.
  - **Query pipeline** (`Infer/ChatViewModel/RAGPipeline.swift`): `runRAGIfAvailable(userText:)` runs on every user turn when the active workspace has an indexed corpus. Embeds the query, top-5 KNN, filters by cosine distance ≤ 1.2, prepends a context block to the user message (not the system prompt — agent personas keep full control of their system prompt). The original user text is what's persisted to the vault; the augmented prompt is what hits the runner. Every failure path downgrades silently to "no augmentation" so retrieval failures never block replies.
  - **Citations** (`Infer/ChatView/ChatTranscript.swift`): assistant messages produced via RAG render a collapsed "Sources" disclosure mirroring `StepTraceDisclosure`'s styling. Header shows source count and best-match similarity (`1 - distance/2` under cosine). Expanded rows show filename, chunk ordinal, distance, preview text (selectable), and a Reveal-in-Finder button. `ChatMessage.retrievedChunks` is ephemeral — session-only, not persisted in the vault (history view shows messages without retrieval provenance in MVP).

- **`InferRAG` library target** (new). Isolates SQLiteVec's bundled SQLite C headers behind a module boundary so they don't collide with GRDB's system-SQLite shim — xcodebuild's workspace-level header map would otherwise pull CSQLiteVec's `sqlite3ext.h` into GRDBSQLite's compile unit, triggering the `sqlite3_db_config → sqlite3_api->db_config` macro redirection without `sqlite3_api` in scope. Contains `VectorStore`, the value types (`VectorSearchHit`, `VectorSourceSummary`, `VectorChunk`, `VectorWorkspaceMeta`, `VectorStoreError`), `TextSplitter` (pure logic, unit-testable), and a thin `RAG.initialize()` wrapper called from `AppDelegate.applicationDidFinishLaunching`. Tested via a new `InferRAGTests` target under `swift test`.

- **Vendored `SQLiteVec` at `thirdparty/SQLiteVec/`** with four local patches. One (moving `sqlite3ext.h` out of the public `include/` dir) is required to unbreak xcodebuild's combined-module-map behavior against GRDB; the others (macOS platform floor bump, passing the DB handle to `SQLiteVecError.check`, adding an `Int64` binding case + fixing `Int` narrowing) are runtime-correctness fixes — without them, any `Int64`-typed parameter (workspace ids, `lastInsertRowId`, Unix timestamps) silently binds as NULL, and SQLite errors surface as bare "Error N" with no message. Full root-cause + re-apply notes in `docs/patches/sqlitevec.md`. Package.swift switches from the GitHub URL to a local path dependency.

- **`swift-tools-version` bumped 6.0 → 6.1.** Required by SQLiteVec's declared minimum (the binary-target form upstream ships to users who don't want to build from source also needs it). Xcode 16.3+ supports 6.1 toolchains.

- **`docs/dev/rag.plan`** — phased plan doc covering the full RAG implementation from workspace-lite prerequisite through query-pipeline + UI integration, with the SQLiteVec pivot documented (original plan proposed vendoring `sqlite-vector` as a dynamic extension; a spike proved Apple strips `sqlite3_enable_load_extension` and stubs `sqlite3_auto_extension`, so the whole `load_extension` path is unusable on Apple platforms).

- **`docs/dev/workspaces.md`** — architecture exploration doc for organizing artifacts (conversations, agents, attachments) as the corpus grows. Explains why flat tags fall short at scale, why workspaces should be *composable views* over typed facets rather than folder hierarchies, and sketches a three-layer refactor (facets table, workspace table, per-workspace VMs with multi-window management). Consumed as input to `rag.plan`'s Phase 0 "workspace-lite" design.

### Changed

- **`ChatMessage` gains `retrievedChunks: [RetrievedChunkRef]?`.** Populated by the RAG query pipeline on the assistant message it's about to generate. Pre-existing transcripts render with it nil, no migration of `steps` or other fields needed.

- **`VaultConversationSummary.tags`** (from the tags feature in 0.1.6) coexists with the new `workspace_id` — workspaces are orthogonal to tags. A conversation can be in the "Acme" workspace and tagged `quarterly-review`; both facets filter independently in the History tab.

- **Deleting a workspace cascades to its vector data.** `deleteWorkspace` now also invokes `vectorStore.deleteWorkspaceData(workspaceId:)` so orphaned sources/chunks/embeddings don't linger in `vectors.sqlite`. Failures in the cascade are non-fatal (derived data — re-ingestable) and logged at warning level.

### Fixed

- **`ggml_abort` crash in `LlamaRunner.setHistory` on longer histories.** `setHistory` submitted the full rendered transcript through a single `llama_batch_get_one` + `llama_decode`. When the token count exceeded `n_batch` (default 512), llama.cpp aborted at `llama-context.cpp:1599` with "n_tokens_all > n_batch". The path wasn't triggered before reasoning-model compaction landed because normal `sendUserMessage` sends turn-sized deltas that stay under the cap. Fix: `setHistory` now chunks the prefill into `llama_n_batch(ctx)`-sized pieces via `advanced(by:)` on the buffer pointer, decoding sequentially and letting llama advance its own position; `n_batch` also raised at load time so chunking fires less often. Reproduced by a long reasoning-model conversation with compaction triggered after each thinking turn.

## [0.1.6]

### Added

- **Agent picker in the chat header.** The active agent is now a first-class header element alongside the model status and token indicator. Click the person-badge label to open a menu grouping compatible agents (activatable) vs. incompatible ones (shown as disabled rows with the reason inline, e.g. "Requires MLX backend"). A "Manage agents…" entry at the bottom routes to the sidebar's Agents tab. Label includes a `tools: N` chip when the active agent exposes tools, so the user can tell at a glance whether the next turn can call tools. `Cmd+Shift+A` opens the Agents sidebar tab (SwiftUI has no API to programmatically open a `Menu`, so the shortcut targets the tab rather than the popover); `Cmd+Shift+I` opens a read-only inspector for the active agent regardless of which tab is active (the sheet is hosted on `ChatView` with `inspectorListing` on the VM, so it doesn't depend on the Agents tab being in the view hierarchy). Sidebar tab selection hoisted from `@State` to `@AppStorage(PersistKey.sidebarTab)` so the "Manage agents…" and inspector commands can route into the right tab.

- **Agent inspector.** Click any row in the Agents library (or use `Cmd+Shift+I`) to open a read-only sheet summarising what the persona will do before activating it: metadata, system prompt (monospaced, selectable, scrollable), exposed tools (with allow/deny lists called out), decoding overrides (diff vs. `InferSettings` — only fields that differ render), and compatibility against the current backend. A "Preview change" toggle expands a bulleted summary of what switching to this agent will change relative to the active one: system-prompt delta, tools added/removed, sampling deltas. Footer offers Reveal/Edit JSON (user personas only), Duplicate, and Activate. Incompatible rows route through the inspector on click instead of silently no-oping — the user learns *why* instead of guessing.

- **Streaming tool-loop visualisation.** `StepTraceDisclosure` now auto-expands while a tool turn is in-flight (derived from `StepTrace.terminator == nil`) and renders progress rows so 2–5 s pauses don't feel like a hang: "running `<tool>`…" with a spinner while the tool is executing, then "awaiting final answer…" once the result is in but the second decode hasn't started streaming. The trace is stamped in three stages inside `maybeRunToolLoop` — request → result → final answer — so intermediate states are observable without introducing an `AsyncStream<AgentEvent>` abstraction. Cancellation and error paths in `send` now finalise incomplete traces with `.cancelled` / `.error` terminators so historical rows can't render a perpetual spinner after a mid-tool stop. User can override auto-expand by toggling the disclosure; the override sticks for the row's lifetime. Label icon swaps hammer → mini `ProgressView` while streaming.

- **Row-click activation + delete for user personas.** Clicking an Agents library row activates it directly (was: menu → "Set as active", 3+ clicks). Subtle accent-tinted hover background signals the affordance. Ellipsis menu keeps secondary actions: View details…, Duplicate (first-party / plugin / Default), Reveal JSON / Edit JSON / Move to Trash… (user personas only). Delete confirms via `.alert` and uses `NSWorkspace.recycle` (moves to Trash rather than unlinking, so a misclick is recoverable from Finder). New `userPersonaURL(for:)` + `deleteUserPersona(_:)` helpers on `ChatViewModel` scan the user agents directory, decode each JSON, and match by `id` — filenames aren't a stable convention since user-authored files can be named anything.

- **Quicksearch over the Agents library.** Search field at the top of the Agents tab filters across name, description, and source tag (case-insensitive substring). Groups collapse automatically when their filtered list is empty; a "No agents match \"X\"" hint replaces the whole listing when nothing matches. Extracted `agentsLibrarySection` into a proper `View` struct (`AgentsLibraryBody`) to hold the `@State` — extension computed vars can't.

- **Library diagnostics banner.** `AgentController.bootstrap` now collects `PersonaLoadError`s from first-party + user persona loading and publishes them as `libraryDiagnostics`. The Agents tab surfaces them as a dismissible orange disclosure at the top ("3 persona files skipped"). Each row shows the filename, the decode error, and a Reveal button. Previously malformed JSON was silently dropped and the user had no way to know a file they edited wasn't being picked up. Diagnostics reset on each bootstrap so they reflect the current state, not an accretion. Two new `AgentControllerTests` cases cover the emit + reset-on-reload paths.

- **Non-modal toast overlay.** New `ToastCenter` (`@Observable`, `@MainActor`) + `ToastOverlay` rendered at the bottom of `ChatView`. One toast at a time, 4 s auto-dismiss, optional inline action button. Duplicating a persona now surfaces "Duplicated \"X\" → filename.json" with a "Reveal" action instead of jumping straight to Finder; deleting a user persona surfaces "Moved \"X\" to Trash." Replaces the previous fire-and-forget behaviour where actions completed invisibly.

- **Unicode-safe agent role labels.** Agent-produced assistant turns in the transcript render with a snapshotted `agentLabel` — a Unicode-safe, single-token flattening of the agent's name (e.g. "Code Helper" → `code-helper`, "日本語 アシスタント" → `日本語-アシスタント`, emoji-only names fall back to the agent id). Previously the role label was computed on the fly from `agentName` using ad-hoc whitespace splitting, which produced awkward output for non-ASCII names and broke with punctuation-heavy names. `AgentListing` now carries a `displayLabel` computed at construction; `ChatMessage` snapshots both `agentName` and `agentLabel` at send time so renaming or deleting a persona never retroactively changes historical rows. Helper is `public static` on `AgentListing` and covered by 8 `AgentListingTests` cases (ASCII, punctuation collapse, CJK preservation, emoji stripping, emoji-only fallback, empty-name fallback, mixed).

### Changed

- **Incompatibility reason visible on hover, not just in row captions.** Disabled "Set as active" menu items now carry the same `.help()` tooltip as the row itself, so keyboard users and anyone hovering the menu learn *why* activation is unavailable rather than just *that* it is. `activationHelp` computed on the row: "This agent is already active.", the incompatibility reason from `AgentController`, or "Switch the current conversation to this agent." depending on state.

- **`AgentDividerRow` gains a hover tooltip.** Transcript divider rendered on mid-conversation agent switches now carries `.help("Active agent switched to \"X\" at this point…")` so a scroll-back through a multi-switch conversation is auditable. The divider still has no timestamp persisted — adding one would require a `ChatMessage.timestamp` migration deferred to a later PR.

- **Parameters' Apply button no longer uses `.borderedProminent`.** Cosmetic: it now matches Reset's plain bordered style instead of rendering as the blue default-action button.

## [0.1.5]

### Added

- **LaTeX math rendering in print / PDF / HTML export.** Transcripts containing `$$…$$`, `\[…\]`, or `\(…\)` now typeset via KaTeX in the `PrintRenderer` WebView before snapshotting, so math lands correctly in PDF export and printed output. Inline `$…$` intentionally excluded to avoid false positives for inline math. KaTeX is loaded parser-blocking at end-of-body, so `WKWebView.didFinish` waits for rendering to complete before `createPDF` fires (no async plumbing). Code blocks are skipped by KaTeX's default `ignoredTags` so fenced code containing `$` isn't mis-rendered. Injection is gated on content detection (`containsMath(_:)`) so transcripts without math skip the ~280 KB of KaTeX JS entirely.

- **Offline web assets (no CDNs).** Both highlight.js and KaTeX now ship inside `Infer.app/Contents/Resources/WebAssets/` instead of loading from cdnjs at runtime. Fetched once per checkout by `scripts/fetch_webassets.sh` (pinned KaTeX 0.16.22 + highlight.js 11.11.1; override via `KATEX_VERSION` / `HLJS_VERSION`) into `thirdparty/webassets/` (gitignored, same pattern as the llama / whisper xcframeworks). New `make fetch-webassets` target + `WEBASSETS_MARKER` rule; `bundle-infer` now depends on it and copies the directory into the app. `PrintRenderer` switched from absolute cdnjs URLs to relative `WebAssets/…` paths with `Bundle.main.resourceURL` passed as `baseURL` on `loadHTMLString`. Motivation: no network at print time, no CDN outage risk, no inadvertent transcript-URL exfiltration, reproducible rendering. Trade-off: `Export as HTML` (standalone .html file) no longer renders code colors or math when opened on another machine — it degrades to plain `<pre>` + raw `$…$`; use `Export as PDF` for a fully self-contained rich artifact.

### Changed

- **Swift 6 strict concurrency.** Dropped `.swiftLanguageMode(.v5)` from `Package.swift`. `LlamaRunner.backendInitialized: static var` replaced with a `static let backendOnce: Void` dispatch-once pattern — Swift's thread-safe `static let` runs the initializer exactly once and later reads are free. Removed both runners' `deinit` bodies (Swift 6 disallows accessing actor-isolated non-Sendable C pointers from a nonisolated deinit); `shutdown()` via `AppDelegate.applicationWillTerminate` remains the cleanup path. Added a `LlamaHandles: @unchecked Sendable` struct to package the llama C pointers (`ctx` / `sampler` / `vocab`) for handoff into `Task.detached` — Sendability is asserted with a comment explaining why it's safe (actor serializes pointer lifecycle against in-flight decodes).

- **Pure text helpers extracted to `InferCore`.** `stripTrailingTrigger` (voice-send phrase detection) moved to `InferCore/VoiceTrigger.swift`; canonical transcript markdown rendering / parsing moved to `InferCore/TranscriptMarkdown.swift` with an intermediate `Turn(role: String, text: String)` shape so the parser doesn't need to know about `ChatMessage`. `ChatViewModel` keeps thin forwarders (`transcriptMarkdown`, `parseTranscript`, `stripTrailingTrigger`) so call sites in the Infer target don't need to change imports. New tests: `VoiceTriggerTests` (8 cases — case-insensitive, punctuation peeling, word-boundary enforcement, empty phrase, custom phrase, text-shorter-than-phrase, phrase-in-middle); `TranscriptMarkdownTests` (7 cases — single/multi-turn round-trip, unknown roles skipped, embedded `---` in content, empty/malformed input, case-insensitive headers). Test count 16 → 31.

- **Deprecation warnings fixed.** Three `String(cString:)` call sites in `LlamaRunner.renderTemplate` and `piece(vocab:token:)` replaced with a shared `decodeCChars(_:length:)` helper that maps `CChar → UInt8` via `bitPattern:` and feeds `String(decoding:as: UTF8.self)`. Also removed the now-unnecessary null-terminator zeroing — the helper uses an explicit byte length rather than walking to a null.

### Added

- **Makefile hygiene targets.**

  - `make clean-infer` — removes only `build/infer-xcode` (xcodebuild derived data). Useful when you want a fresh xcodebuild without blowing away the bundled `.app`.

  - `make clean-mlx-cache` — reports `du -sh` of `$HF_HOME/hub` (defaults to `~/.cache/huggingface`) and prompts for confirmation before `rm -rf`. MLX model downloads grow unbounded; this is the safe way to reclaim the disk.

## [0.1.4]

### Changed

- **Centralized file-dialog helpers.** New `FileDialogs.swift` wraps `NSOpenPanel` / `NSSavePanel` behind three static methods (`openFile`, `openDirectory`, `saveFile`). Seven call sites across `Loading.swift`, `Attachments.swift`, and `Transcript.swift` collapsed from inline panel configuration (`allowsMultipleSelection = false`, `canChooseDirectories = …`, `allowedContentTypes = …`, `runModal()` → `.OK`) to single-line calls. `ChatViewModel.markdownContentTypes` extracted to avoid duplicating the `.md` UTType fallback between save and load paths. Cleanup pays off standalone; also shortens the future iOS port (the one file to replace with SwiftUI `.fileImporter` / `.fileExporter`).

### Added

- **Stop Speech keyboard command.** New **Speech > Stop Speaking** menu item bound to ⌘⇧. — parallels ⌘. (Stop generation) and shuts up TTS mid-sentence at any time. Works regardless of continuous voice or barge-in state; disabled when nothing is speaking. Useful when running on laptop speakers where barge-in would self-trigger from the TTS audio picked up by the mic.

- **TTS barge-in.** In voice-loop mode, speak over the assistant's reply to interrupt it — the mic instantly swings over to dictation so the user can start their next turn without waiting through the rest of the TTS. New `TTSBargeInMonitor` in `SpeechServices.swift` owns a dedicated `AVAudioEngine` (separate from `SpeechRecognizer`'s), installs a tap on the input node, computes RMS per buffer → dBFS, and fires once when the level stays above `-30 dBFS` for `≥ 200 ms`. Not `@MainActor` (tap runs off-main); shared timing state is `NSLock`-protected, and the single user-visible callback hops to main. Single-shot per arm: monitor auto-tears-down on fire. Sub-toggle **"Barge-in (interrupt TTS by speaking)"** added under the Continuous voice toggle, indented, disabled when the loop is off; defaults on (via `UserDefaults.object` lookup so absent key reads as `true`). Added `SpeechSynthesizer.onCancel` as a complement to `onFinish` so observers can distinguish user Stop from natural completion — `onFinish` triggers auto-arm, `onCancel` only tears down the monitor. `ChatViewModel.speakAssistantReply(_:)` centralizes TTS dispatch and monitor arming; Generation.swift calls it on completion. Failure modes: no input device or engine start failure → stderr log + barge-in disabled for that session, TTS still plays. Threshold and sustain duration are code constants (`-30 dBFS`, `200 ms`) — promote to UI if field tuning is needed. Self-feedback from external speakers is a known v1 limitation (AEC is a separate, much bigger project).

- **Silence-based voice-send.** Alternative auto-submit trigger for dictation: set "Or send after silence: N sec" in the Voice sidebar and the in-flight turn submits after N seconds without a new partial transcript arriving. Works alongside the voice-send phrase — whichever fires first wins; empty transcript at timeout is a no-op. Implemented as a `Task.sleep`-based timer reset on every partial update in `ChatViewModel.startDictation`; cancelled on trigger-phrase match, manual stop, or next dictation session. Guards on fire: text non-empty, model loaded, recognizer still recording — so the timer can't race with a manual stop. Persisted as a string under `PersistKey.voiceSendSilenceSeconds` (empty = disabled, distinguishing absence from 0). Default disabled. Works both inside and outside continuous-voice mode.

- **Voice-loop mode.** New "Continuous voice (auto-mic after reply)" toggle in the Voice sidebar. When on: TTS is force-enabled, the mic arms immediately, and after each assistant reply is spoken the mic auto-arms so the user can dictate the next turn — dictation + trigger phrase (`"send it"` default) + TTS + auto-arm becomes a hands-free loop. Built on an `onFinish` callback added to `SpeechSynthesizer` that fires only on natural `didFinish`, not on `didCancel`, so a user-initiated Stop (mid-TTS or mid-generation) pauses the loop cleanly — a subsequent successful turn resumes it. Disabling TTS while the loop is on clears the flag automatically (no `didFinish` would ever arrive). Factored the mic-button logic out of `ChatComposer` into `ChatViewModel.toggleDictation()` / `startDictation()` so manual and auto-arm share one path. Warns in the Speech sidebar if the loop is on but `voiceSendPhrase` is empty (nothing would submit the turn). TTS barge-in (talking over a long reply) is a separate follow-up; without it the loop is polite but you have to let each reply finish. Persisted under `PersistKey.continuousVoice`.

## [0.1.3]

### Added

- **Sampling seed (reproducibility).** New `seed: UInt64?` field on `InferSettings`; `nil` = random (non-deterministic, prior behavior). When set, identical prompt + params + seed produces identical output on a given backend. Sidebar's Parameters section grows a Seed row: text field (empty = random), a **Random** button that pins a fresh random seed, and a **Clear** button that reverts to random-per-generation. Wired through both runners: `LlamaRunner` narrows the `UInt64` to `UInt32` (what `llama_sampler_init_dist` takes) and installs it in the sampler chain at load / `updateSampling`; `MLXRunner` calls `MLX.seed(_:)` immediately before each generation (safe because generations are serialized via `isGenerating`). Persisted as a string under `PersistKey.seed` since `UserDefaults` has no `UInt64` path; two new `SettingsPersistenceTests` cover round-trip at `UInt64.max` and clearing-after-setting leaves no residue (14 → 16 tests). `Package.swift` now declares `mlx-swift` directly to expose the `MLX` product for `MLX.seed`.

- **Regenerate last response.** Hover over the most recent assistant message to reveal a circular-arrow button next to Copy; click to re-sample a new reply for the same user turn. Both backends rewind their KV cache and re-prefill from the truncated transcript: `LlamaRunner.rewindLastTurn()` drops the last user+assistant pair, clears the llama KV via `llama_memory_clear`, and resets `prevFormattedLen` so the next send re-tokenizes the full template in one batch; `MLXRunner.rewindLastTurn()` drops the last pair from the tracked `history: [Chat.Message]` so the next session rebuild inherits the truncated state. The transcript's original user text + image attachment are restored into the composer and then re-sent via the normal `send()` path. Button is hidden while generating, while no model is loaded, or when the last two messages aren't a user→assistant pair (so partial / cancelled replies can't be regenerated — runner history would be out of sync).

- **Edit + resend last user message.** Pencil icon appears on hover over the last user turn (same conditions as Regenerate); click to pop the user+assistant pair back into the composer without sending. Shares plumbing with Regenerate via a private `unspoolLastTurn()` helper — both call the same runner `rewindLastTurn()` methods. Difference is the terminal step: Regenerate auto-dispatches `send()`; Edit hands control back to the user so they can modify the text before re-submitting.

- **Restore backend context on transcript load.** `loadTranscript()` (`File > Open Transcript…`) and `loadVaultConversation()` (History sidebar) used to replace the UI transcript but reset both backends — the model had no memory of the loaded turns, so any follow-up message started from zero context. Now: both paths call a shared `restoreBackendHistory(_:)` that rebuilds each runner's KV state from the loaded messages. `LlamaRunner.setHistory(_:)` clears the KV cache, installs the system prompt + provided turns into its private messages array, renders the chat template, tokenizes, and submits one `llama_decode` batch to pre-fill (~one prompt-sized decode on load). `MLXRunner.setHistory(_:)` takes a dependency-free tuple shape (so the VM doesn't import `MLXLMCommon`) and translates to `[Chat.Message]`; the next send rebuilds the `ChatSession` with `history:` and pre-fills automatically. System turns from the transcript are filtered — each runner uses the current `settings.systemPrompt`. Llama pre-fill failures silently fall back to a reset so the transcript stays readable.

### Fixed

- **MLX multi-turn context loss.** `MLXRunner.sendUserMessage` rebuilt the `ChatSession` on every send to apply per-turn `maxTokens`, but the new session initialized with an empty KV cache — so prior-turn context was silently discarded on every message. `MLXRunner` now tracks a `history: [Chat.Message]` array and rebuilds via `ChatSession(..., history:)`, preserving context across rebuilds. Completed turns are appended only on clean stream completion so a cancelled/errored send doesn't anchor the next turn to a partial reply. `updateSettings` no longer eagerly rebuilds (next send picks up the new params with history intact); `resetConversation` / `shutdown` clear history. New `setHistory(_:)` entry point unblocks upcoming regenerate / transcript-restore flows.

## [0.1.2]

### Changed

- **`ChatView.swift` split into 18 files across three subfolders.** The monolithic 2444-line file containing `ChatViewModel`, `ChatView`, `SidebarView`, and a dozen helper views was broken up into `ChatView/`, `ChatViewModel/`, and `Sidebar/` directories under `Sources/Infer/`. `ChatViewModel` is now one core file plus seven extension files, one per concern (Loading, Generation, Settings, Transcript, VaultHistory, Attachments, Speech). Previously-`private` stored properties accessed across concerns are now target-internal. No behavior change.

### Added

- **Unified model picker.** A single dropdown in the Model sidebar lists every downloaded model across both backends, tagged `[GGUF]` or `[MLX]`. Sources are unioned: (1) vault-tracked entries ordered by last-used, (2) a scan of `$HF_HOME/hub/models--*/snapshots/` for MLX weights, (3) a scan of the configured GGUF folder for `*.gguf` files. Selecting an entry switches the backend segment and fills the text field; Load performs the actual load so the choice is always explicit.

- **Unified model input.** One text field, interpretation driven by the backend segment. MLX: HF repo id (empty = registry default). Llama: absolute `.gguf` path, bare filename resolved against the configured GGUF folder, or `http(s)://` URL — URLs stream-download via `URLSession` into the GGUF folder (progress bar + Cancel), then load. `Content-Disposition` filename is honored; collisions get a `-N` suffix.

- **GGUF folder setting.** Configurable via the Model sidebar ("Change…" / "Reset"). Default: `~/Library/Application Support/Infer/Models/` (auto-created). Persists in `UserDefaults` under `infer.ggufDirectory`.

- **Model registry in the vault.** New `models` table (migration `v2_models`) tracks `(backend, model_id, source_url, last_used_at)`. Every successful load upserts a row; autoload on launch iterates the table in last-used order and picks the first entry whose artifact still exists on disk (stats path for llama, checks HF snapshot dir for MLX).

### Changed

- **Model sidebar redesign.** Replaces the previous per-backend "recent models" dropdown + separate HF-id text field + Browse-or-Load button with a unified dropdown, always-visible text field, and a dedicated Load button (Browse… appears alongside for llama). Removed `infer.recentLlamaPaths`, `infer.recentMLXIds`, `infer.lastLlamaPath`, `infer.lastMLXId` UserDefaults keys — the vault's `models` table supersedes them.

### Fixed

- **`Clear vault…` crash.** `VaultStore.clearAll()` was issuing `VACUUM` inside a GRDB write transaction, which SQLite rejects. Split into a transactional `DELETE` followed by `writeWithoutTransaction { VACUUM }`.

## [0.1.1]

### Added

- **SQLite-backed conversation vault.** Every new chat is persisted to `~/Library/Application Support/Infer/vault.sqlite` (WAL mode) via GRDB. FTS5 full-text search across all past conversations from a **History** sidebar tab with search-as-you-type (250 ms debounce), recent-conversations list, per-row delete, and a guarded "Clear vault…" action. Clicking a result loads that conversation into the UI; further turns append to the same vault row. Vault writes are best-effort and never block generation. Conversation row is created lazily on first `send()`; `reset()`, system-prompt changes, and `.md` import all start a fresh row on the next send.

- **whisper.cpp file transcription.** Drag audio or video onto the window (`.wav`, `.mp3`, `.m4a`, `.aac`, `.aiff`, `.caf`, `.flac`, `.mp4`, `.mov`, `.ogg`, `.opus`) → whisper transcribes → transcript appears in the composer prefixed with `[Transcript of <filename>]`. Fetched from `whisper.xcframework` v1.8.4 by `scripts/fetch_whisper_framework.sh` and bundled into `Infer.app/Contents/Frameworks/`. Default model is `base` (multilingual, 142 MB); `tiny` and `small` are also selectable. Models download to `~/Library/Application Support/Infer/whisper/ggml-<size>.bin` on first use with a progress bar in the sidebar and a banner above the composer. Translate-to-English toggle in the Voice tab. SFSpeechRecognizer live dictation is unchanged — whisper is file-only.

- **In-app voice recording.** Record / Stop button in the Voice tab captures the mic to a `.wav` at the input device's native format (`~/Library/Application Support/Infer/recordings/recording-YYYYMMDD-HHmmss.wav`) and auto-transcribes via whisper on stop. Live duration readout while recording; cancel (×) discards the in-flight file. "Reveal in Finder" and "Clear recordings…" (NSAlert-confirmed) actions alongside.

- **App icon.** Placeholder 1024×1024 squircle generated programmatically from `scripts/generate_app_icon.swift` (CoreGraphics → `iconutil`). Indigo→violet gradient with a three-input-to-one-output inference glyph. `bundle-infer` now copies `projects/infer/Resources/AppIcon.icns` into `Infer.app/Contents/Resources/`. Regeneratable via `make generate-icon`.

- **CWhisperBridge** C target in `Package.swift`. Narrow wrapper over `whisper.h` that exposes only primitive-typed functions, isolating whisper's bundled `ggml.h` from the Swift module graph so the Infer target can also import `llama` (which ships its own, incompatible `ggml.h`) without a Clang type-redefinition error.

- `VaultStore.shutdown()` and `WhisperRunner.shared.shutdown()` are wired into `AppDelegate.applicationWillTerminate` alongside the llama / MLX cleanups, giving the vault a deterministic WAL checkpoint on quit and releasing the whisper context.

- Collapsible right sidebar (⌘-toggled via a header button) with four sections, replacing the previous gear popover:

  - **Parameters**: Temperature / Top P sliders, Max tokens stepper-as-slider, collapsible System Prompt editor with Reset / Apply.

  - **Model**: segmented backend picker, per-backend "recent models" dropdown (paths for llama, HF ids for MLX), HF repo-id field, Load / Browse / Cancel button.

  - **Speech** (see below).

  - **Appearance**: Light / Dark / System segmented picker; default is Light.

- On-device speech dictation via `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. Mic button on the left of the composer toggles recording; partial transcripts append to the current composer text via a configurable baseline so the user's existing draft is preserved.

- Text-to-speech for assistant responses via `AVSpeechSynthesizer`. Toggleable "Read responses aloud" with a voice picker (listing all installed macOS voices sorted by language) and a Preview / Stop pair. Auto-speaks the completed assistant message when enabled.

- Voice-send trigger phrase: say a configurable phrase (default `"send it"`) at the end of a dictation to strip it and auto-submit. Requires a word boundary so `"resend it"` doesn't match. Editable from the Speech sidebar.

- Composer expander: `>` chevron left of the text field; click or Shift+Return swaps the single-line `TextField` for a multi-line `TextEditor` (120–260pt). Auto-collapses after send. Cmd+Return always submits; Return submits when collapsed, inserts a newline when expanded.

- Auto-scroll pause: transcript follows the bottom during streaming only when the user is pinned there. Scrolling up unpins; a "↓ Jump to latest" capsule pill appears at the bottom and re-pins on tap. Sending a new message re-pins automatically.

- Context-window indicator in the header: progress bar + `used / total` token count for llama (exposes `llama_n_ctx`), approximate `~N tok` for MLX (char-count estimate). Bar tints orange >80%, red >95%.

- Per-message copy button: hover-reveal icon on each message row; copies that single turn to the pasteboard with a brief green-checkmark confirmation.

- `File > Open Transcript…` (⌘O) and `File > Save Transcript…` (⌘S): read / write the canonical markdown format produced by Copy as Markdown. Loading replaces the UI transcript and resets both backends (backend context is not restored — see TODO).

- `File > Export as HTML…` and `File > Export as PDF…` (⌘⇧E). Exports reuse the same styled HTML as Print. PDF export explicitly paginates the `WKWebView` tall-page output into paper-sized pages via `CGContext` / `CGPDFContext`, respecting `NSPrintInfo.shared.paperSize` (Letter or A4 per locale).

- Tokens/sec readout in the header during and after generation: `123 tok · 45.2 tok/s`, computed from stream-piece count and wall-clock. Accent color while generating, secondary once complete; cleared on Reset.

- Syntax highlighting in the print / export HTML pipeline via `highlight.js` (GitHub theme, loaded from the cdnjs CDN with an inline `hljs.highlightAll()` call). Graceful degradation when offline.

- Improved table styling in the print / export HTML: full-width, zebra-striped rows, header-row background, italic `<caption>` support.

- Info.plist: `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` strings so the OS can present the privacy prompts for dictation.

- `scripts/space_bullets.py`: argparse-based utility that inserts blank lines between adjacent markdown bullets; supports `--in-place`, `--recursive` (with a dry-run by default), `--glob`, and `--exclude` (default excludes `.git`, `.build`, `build`, `node_modules`, `.venv`, `venv`).

### Changed

- **Sidebar reorganized into icon tabs.** The sidebar is now four icon tabs at the top (Model, History, Voice, Appearance) instead of a single scrolling column of sections. The Model tab contains both Model and Parameters (both affect inference); single-content tabs drop their redundant section header. Selection is not persisted across launches.

- Transcript auto-scroll is now conditional on a `pinnedToBottom` flag derived from a bottom-sentinel `onAppear` / `onDisappear` inside the `LazyVStack`, replacing the previous unconditional `proxy.scrollTo(last.id)` on every token.

- `PrintRenderer` refactored: `transcriptHTML(_:)` is now a pure function reused by print / HTML export / PDF export. The `renderPDF(for:completion:)` pipeline is shared and keyed by `ObjectIdentifier` so concurrent operations no longer stomp on a single static `pending` slot.

- MLX model-download status shows an indeterminate spinner with "Resolving …" until the first byte-progress callback fires, then switches to the determinate bar labelled "Downloading …". Previously a misleading "0%" sat on screen during the HF metadata phase.

- `pre` blocks in exported / printed HTML now `white-space: pre-wrap` with `overflow-wrap: anywhere`; long code lines wrap within the page instead of overflowing and getting clipped by `createPDF`.

- Preferred color scheme defaults to Light and is persisted under `infer.appearance` via `@AppStorage`.

### Fixed

- Exported PDFs are now multi-page and correctly paper-sized. `WKWebView.createPDF` always emits a single tall page; the prior export implementation wrote that tall single page to disk (~17-inch height) or fit-scaled it onto one page (cutting off the top). Export now slices the tall source into paper-sized pages via a `CGContext` PDF consumer.

- Exported PDF layout width no longer depends on `NSPrintInfo.shared`'s current margin state. The `WKWebView` frame width is computed as `paperSize.width − 2*pageSideMargin` from a dedicated `pageSideMargin` constant, so Print and Export produce identical page geometry.

- SFSpeechRecognizer fast-path: when permission is already authorized, `start()` now uses synchronous `authorizationStatus()` and skips the async `requestAuthorization` round-trip, so the mic button transitions to `.recording` on the same runloop as the tap. Added an `isStarting` re-entrancy guard so rapid double-clicks during the first-time permission flow can't corrupt state.

- SFSpeechRecognizer no longer forces `requiresOnDeviceRecognition = true` unconditionally; it's now gated on `supportsOnDeviceRecognition`. Non-benign errors are surfaced to the Speech sidebar (previously swallowed).

## [0.1.0]

### Added

- SwiftUI chat app with two inference backends selectable at runtime via a header picker.

  - `llama.cpp` backend: loads a local `.gguf` file through `llama.xcframework` (downloaded by `scripts/fetch_llama_framework.sh`).

  - MLX backend: loads any MLX-compatible Hugging Face repo id via `mlx-swift-lm` (Mode 1 integration using `#huggingFaceLoadModelContainer`); defaults to `LLMRegistry.gemma3_1B_qat_4bit`.

- `scripts/fetch_llama_framework.sh`: downloads a tagged `llama-<tag>-xcframework.zip` from the llama.cpp releases and installs `thirdparty/llama.xcframework` (default tag `b8848`).

- Makefile targets: `fetch-llama`, `build-infer`, `bundle-infer`, `run-infer`.

- Markdown rendering for assistant messages via `swift-markdown-ui` with the `gitHub` theme.

- Swift syntax highlighting for fenced code blocks via `Splash` (other languages render monospaced/themed but uncolored).

- Hyperlinks in assistant messages open in the default browser (custom `OpenURLAction` routing to `NSWorkspace.shared.open`).

- Auto-load the last successfully loaded model on app launch (backend + path/HF id persisted in `UserDefaults`).

- `Edit > Copy Transcript as Markdown` (⇧⌘C): copies the full session as markdown (one `## <role>` block per message, separated by `---`).

- `File > Print Transcript…` (⌘P): renders the transcript through `swift-markdown`'s `HTMLFormatter` into a styled HTML document, loads it in an off-screen `WKWebView`, snapshots via `createPDF(configuration:)`, and prints through `PDFDocument.printOperation` for reliable pagination.

- Header settings popover (gear icon) with:

  - System prompt (multi-line `TextEditor`), applied to `ChatSession(instructions:)` on MLX and prepended as role=`system` on llama.

  - `temperature` and `top_p` sliders — rebuild the llama sampler chain / MLX `GenerateParameters` without requiring re-load.

  - `max_tokens` stepper, applied per-send on both backends.

  - Settings persist across launches in `UserDefaults`.

- Determinate progress bar for MLX model downloads via the `progressHandler` variant of `#huggingFaceLoadModelContainer`.

- `Cancel` button in the header while a load is in flight; cancels the load `Task` and rolls the UI back to the pre-load state.

### Changed

- Migrated from CMake to Swift Package Manager.

- `make build-infer` uses `xcodebuild` (not `swift build`) because mlx-swift's Metal kernels can only be compiled by Xcode's Metal toolchain; this requires the separate Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`, ~700 MB, one-time).

- `bundle-infer` embeds `llama.framework` (from the `macos-arm64_x86_64` xcframework slice) into `Infer.app/Contents/Frameworks/` and copies SPM-emitted resource bundles (including `mlx-swift_Cmlx.bundle` containing `default.metallib`) into `Infer.app/Contents/Resources/`.

- Transcript background now uses `Color(.textBackgroundColor)` so it follows the system light/dark appearance.

### Notes

- First MLX model load downloads to `~/.cache/huggingface/hub/` (standard HF cache layout; override with `HF_HOME`).

- Prerequisites: Xcode 16.3+ / Swift 6.1+ (required by `mlx-swift-lm`).

- Load cancellation for the llama backend is cooperative: `llama_model_load_from_file` is a synchronous C call, so `Task.cancel()` only takes effect at the next Swift await point (fine for HF downloads, best-effort for large `.gguf` mmap).

- Changing the system prompt resets the conversation on both backends (history is lost); sampler param changes (`temperature`, `top_p`) do not.
