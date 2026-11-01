# Design: `whisper.transcribe` and "Add to workspace"

Status: `whisper.transcribe` version 1 and "Add to workspace" are implemented. `whisper.transcribe` version 2 is not.

Build `whisper.transcribe` first. It reads a file and returns text, so a mistake ends with the turn. The proposed `workspace.ingest` tool is replaced by a user action, because ingested text persists into later turns.

## Tool shape

`whisper.transcribe` follows `VaultSearchTool`: the tool lives in `InferAgents` and receives a closure from the app. `WhisperRunner` lives in the `Infer` target, which `InferAgents` cannot import. The closure also lets `make test` cover the tool without a model.

No first-party persona lists the tool until one opts in through `toolsAllow`.

## `whisper.transcribe`

### Constraints in the current code

- `whisper_bridge_transcribe` calls `whisper_full` once and blocks until it returns. It sets no `new_segment_callback` or `abort_callback`.
- Stop cannot interrupt a run, for the same reason.
- `WhisperRunner` is shared with dictation and the Speech sidebar. A long tool run queues both.
- `WhisperRunner.load` frees the current model when the path differs.
- `AudioDecoder` loads the whole file into memory, about 460 MB for 2 hours.
- The bridge sets no language. whisper.cpp's default is `en`, as far as I recall; confirm this before relying on it. Non-English audio may transcribe poorly.

### Version 1

Arguments: `{path, translate?}`. It returns the transcript as a single result.

| TODO proposal | Decision | Reason |
|---|---|---|
| Streamed partials | Defer | Needs a bridge change. A blocking result works for short files. |
| `model` argument | Drop | A model-chosen model would evict the one dictation uses. Use `WhisperModelManager.selected`. |
| `language` argument | Defer | Needs a bridge change. |

Rules:

- **Sandbox:** the same roots as `fs.read`, plus `Infer/recordings` for in-app recordings.
- **Missing model:** return an error. Never call `ensureDownloaded` from a tool, because a model should not start a download of hundreds of MB.
- **Duration cap:** refuse files over 30 minutes before decoding. The run cannot be cancelled, so the cap bounds how long Stop has no effect.
- **Output cap:** 64 KB with a truncation marker, matching `fs.read`.

Tests use a stub closure and cover the sandbox, symlink escape, missing model, duration cap, truncation and `translate` forwarding.

### Version 2

Change the bridge once, adding three parameters: segment callback, abort flag and language. Then:

- Move the tool to `StreamingBuiltinTool`, with `.log` per segment.
- Connect Stop to the abort flag.
- Remove the duration cap.

Test the bridge in an `*ExternalTests` suite.

## Add to workspace (replaces `workspace.ingest`)

### Failure mode that decides the design

Fetched text that enters a conversation today leaves with that conversation. Ingested text stays. A page containing instructions would be retrieved in later turns, by any agent and in any conversation in that workspace, including agents holding `fs.write`. That is persistent prompt injection.

Built-in tools have no per-call consent. `MCPApproval` approves a server at bootstrap only.

### Gaps in the original TODO entry, and their resolution

- **Entry point:** `WorkspaceManager.ingest(url:)` did not exist. `DocumentIngest.ingest` now holds the split, embed and store sequence for every caller.
- **Host allowlist:** `http.fetch` allows two hosts, so the proposed search, fetch, ingest flow failed on most results. The user action has no allowlist, because a person chooses each URL.
- **File types:** files and URLs accept text, JSON and PDF, and URLs also accept HTML. HTML reduction uses regexes and keeps `<main>` or `<article>` content when marked. A nested `<nav>` can leave a fragment. PDF text comes from PDFKit, so scans fail.
- **Duplicates:** `sourceURI(workspaceId:contentHash:)` detects them before embedding.
- **Changed content:** added sources replace older content at the same URI, after embedding succeeds.
- **Concurrency:** the action shares `ingestProgress` with scans, so the two cannot overlap. `EmbeddingRunner.embed` does not suspend, so the actor already serializes embedder calls.
- **Missing embedder:** the action reports an error instead of skipping silently.

### Options

| | A: confirm per call | B: user action only | C: no gate |
|---|---|---|---|
| Change | Tool plus a new confirmation seam | "Add file..." and "Add URL" in the workspace sheets, no tool | Tool only |
| Injection risk | User reviews each source | User chooses each source | Open |
| Agent autonomy | Pauses for the user | None | Full |
| Cost | Highest | Lowest | Low |

**Decision: B.** It delivers the main benefit, keeping a source for later questions, without a new consent seam. Agents get no ingest tool. Revisit A only if unattended agents need to pause and ask. C is rejected.
