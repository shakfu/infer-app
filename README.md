# infer

A macOS SwiftUI chat app with two local inference backends selectable at runtime:

- **llama.cpp** via `llama.xcframework`

- **MLX** via `mlx-swift-lm`

Plus, local speech-to-text via `whisper.cpp` (file drop and in-app recording), on-device dictation via `SFSpeechRecognizer`, TTS, a searchable SQLite vault of all conversations, Markdown/PDF/HTML transcript export, document rendering via an external Quarto installation, a sandboxed [tool runtime](#built-in-agent-tools) (filesystem read/write/list, PDF text extraction, XLSX read + write, CSV/TSV writing, clipboard, math, vault + Wikipedia + web search, HTTP fetch with allowlist, plus MCP-server tools), and a [compile-time plugin system](#plugins) (Python execution via an embedded interpreter, more to come).

Built with Swift Package Manager and `xcodebuild`.

## Prerequisites

- macOS 14.0+

- Xcode 16.3+ with Swift 6.1+ (required by `mlx-swift-lm`)

- Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain` (~700 MB, one-time)

## Install

```sh
# check if you have the metal tool chain install
xcodebuild -showComponent MetalToolchain

# if you confirm it not installed via something like this
Build Version: 17E188
Status: uninstalled

# then
xcodebuild -downloadComponent MetalToolchain

# First run downloads llama.xcframework, whisper.xcframework, and
# KaTeX + highlight.js (for offline math/syntax rendering in PDF/print)
# into thirdparty/.
make
```

## Build

```sh
make bundle               # -> build/Debug/Infer.app
make run                  # Open Infer.app (Debug)

# Optimized build for perf testing / distribution dry-runs:
make bundle-release       # -> build/Release/Infer.app
make run-release
```

Debug is the default because it's what active development wants (fast incremental rebuilds, full debug symbols). Release turns on `-O` and strips symbols; the two bundles coexist under `build/Debug/` and `build/Release/` so switching configs doesn't force a rebuild of the other side.

`make build` uses `xcodebuild` (not `swift build`) because mlx-swift's Metal kernels can only be compiled by Xcode's Metal toolchain. The `llama.xcframework` is fetched by `scripts/fetch_llama_framework.sh` from the [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases); override the tag with `make build LLAMA_TAG=bXXXX`. The `whisper.xcframework` is fetched by `scripts/fetch_whisper_framework.sh` from the [whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases); override with `WHISPER_TAG=vX.Y.Z`. `KaTeX` + `highlight.js` are fetched by `scripts/fetch_webassets.sh` (override versions via `KATEX_VERSION` / `HLJS_VERSION`) into `thirdparty/webassets/` and bundled into `Infer.app/Contents/Resources/WebAssets/` — no CDNs at runtime.

Other native deps come in via SPM and compile from source on first build: `libxlsxwriter` (BSD-2-Clause, used by `xlsx.write` — adds `-lz` link, no fetch script, no binary blob), `CoreXLSX` (Apache-2.0, used by `xlsx.read`; pulls XMLCoder + ZIPFoundation transitively), and `SQLiteVec` (MIT, vendored at `thirdparty/SQLiteVec/`, used by the RAG vector store).

At runtime the app offers two backends via a header picker:

- **llama.cpp** — click `Load Model…` and pick a local `.gguf` file.

- **MLX** — leave the HF repo id empty to use `LLMRegistry.gemma3_1B_qat_4bit` (~700 MB, downloaded on first use to `~/.cache/huggingface/hub/`), or paste any MLX-compatible HF id like `mlx-community/Qwen3-4B-4bit`.

## Speech

The **Voice** sidebar tab exposes live dictation, TTS, a hands-free voice loop, and whisper file transcription.

- **Live dictation** — mic button on the composer uses Apple's on-device `SFSpeechRecognizer`. Partial transcripts stream into the composer. Two auto-submit triggers (independent, whichever fires first wins):

  - **Voice-send phrase** — say the configured phrase (default `"send it"`) at the end of a dictation.

  - **Silence timeout** — set "Or send after silence: N sec" and the in-flight turn submits after N seconds without new speech.

- **Text-to-speech** — toggle "Read responses aloud" to have `AVSpeechSynthesizer` speak each completed assistant reply; voice pickable from all installed system voices.

- **Continuous voice (voice loop)** — toggle on for a hands-free cycle: TTS reads the assistant reply, then the mic auto-arms so you can dictate the next turn. Submitting (via phrase or silence) kicks off the next generation, and the loop continues. Force-enables TTS; turning TTS off clears the loop.

  - **Barge-in** sub-toggle (on by default when in loop mode): talk over the TTS to interrupt it — the mic swings straight into dictation without waiting for the reply to finish. Runs a dedicated `AVAudioEngine` tap that fires when input level stays above `-30 dBFS` for ≥ 200 ms. **Use headphones** — on laptop speakers the TTS audio leaks back into the built-in mic and self-triggers. Disable the sub-toggle for speaker use.

  - **Stop Speech** (⌘⇧.) — menu shortcut under `Speech > Stop Speaking` shuts up TTS mid-sentence. Works regardless of loop/barge-in state; handy on speakers.

- **File transcription (whisper.cpp)** — drag any audio or video file onto the window, or press **Record** to capture the mic to a `.wav`, and whisper transcribes the result into the composer. Model choice (`tiny` / `base` / `small`, all multilingual), translate-to-English toggle, and recordings actions (Reveal in Finder, Clear recordings…) live in the same tab. Whisper models download on first use to `~/Library/Application Support/Infer/whisper/`; recordings are saved to `~/Library/Application Support/Infer/recordings/`.

## Conversation vault

Every new chat is saved to `~/Library/Application Support/Infer/vault.sqlite` (GRDB + FTS5). The **History** sidebar tab has search-as-you-type across all past messages and a recent-conversations list; clicking a result loads it into the UI. Markdown transcript save/load is still available via `File > Save/Open Transcript…` but is independent of the vault.

Loading a conversation (from the History tab or `File > Open Transcript…`) restores the model's KV cache from the loaded messages, so follow-up turns have full prior context. Cost is one prompt-sized decode at load time on both backends.

## Conversation actions

Hover over the latest turn of either role to reveal inline actions:

- **Regenerate** (assistant row, circular arrow) — resample a new reply for the same user turn.

- **Edit + resend** (user row, pencil) — pop the last user/assistant pair back into the composer for editing before resending.

Both rewind the backend's KV cache and re-prefill from the truncated transcript. Available only when the VM is idle and the last two messages are a user→assistant pair.

## Quarto rendering

The bundled **Quarto renderer** agent generates Quarto (`.qmd`) source from a description and renders it to HTML, PDF, DOCX, PowerPoint, Reveal.js slides, Typst, LaTeX, EPUB, etc. — via your local Quarto installation. Quarto itself isn't bundled; the app finds it on `PATH` (or a path you pin in settings), so upgrades are independent of the app and there's no signing/notarization burden.

**Setup (one-time)**

1. Install Quarto: `brew install quarto` (or download from [quarto.org](https://quarto.org/docs/get-started/)).
2. Open the **Tools** tab in the sidebar (wrench icon). The Quarto card shows a live status badge — `Quarto 1.9.37` in green when found, `not found` in orange otherwise. If the app's GUI environment doesn't see your shell's `PATH` (common on macOS), use **Browse…** to point at `/usr/local/bin/quarto` or `/opt/homebrew/bin/quarto` and click **Apply**.

**Use**

1. Sidebar → **Agents** tab → activate **Quarto renderer**. Requires a llama.cpp model with a tool-calling template (Llama 3.x, Qwen 2.5+/3, Hermes-3); MLX is not supported by the agent today.
2. In chat, ask for the format you want:

   ```
   Create a powerpoint presentation on how to write a short story.
   ```

   ```
   Convert the following to PDF:

   ---
   title: "Quarterly Report"
   ---

   ## Summary

   Body text.
   ```

3. Watch the disclosure: a streaming-progress sub-line under "running builtin.quarto.render…" surfaces Quarto's stderr (typst startup, pandoc invocation) so a 5–30 s render isn't silent.
4. Click the rendered filename in the disclosure to open the result via Launch Services (PDF → Preview, HTML → default browser, PPTX → Keynote / PowerPoint).

**Render cache**

Renders stage under `~/Library/Caches/quarto-renders/`. macOS does not auto-clean app caches; the **Tools** tab's "Render cache" row shows the file count + total size, with **Show in Finder** and **Clear…** buttons. Clearing removes every staged render — links from past chat messages stop working.

**Format conventions the agent knows**

- `pptx` / `revealjs` / `beamer`: `#` for section/title slide, `##` for content slide with bullets, 3–6 bullets per slide.
- `pdf` / `html` / `docx` / `epub`: ordinary `#` for chapter, `##` for section, prose body.
- `typst` / `latex`: Quarto-flavored markdown (the agent does *not* emit raw Typst/LaTeX); Quarto compiles to those targets from markdown.

The agent's system prompt teaches these conventions and includes a worked pptx example. Smaller models (1B-3B params) can drift back to prose; if that happens, either prompt explicitly ("as slides with one bullet per point") or load a larger model.

## Built-in agent tools

Agents can opt into a per-agent allowlist of these tools through their JSON config (`requirements.toolsAllow`). Sandbox roots and HTTP allowlists are configured at registration time in `ChatViewModel.bootstrapAgents`.

| Tool | What it does | Sandbox / safety |
|---|---|---|
| `fs.read` | Read a UTF-8 text file | `~/Documents` + agents root; symlink-resolved before allowlist check; 64 KB cap with truncation marker |
| `fs.write` | Write a UTF-8 text file (atomic) | Same roots; refuses overwrite unless `overwrite: true`; refuses to create parent dirs; 1 MB cap |
| `fs.list` | List a directory (optionally recursive) | Same roots; 200-entry cap, depth-4 cap; hides dotfiles by default |
| `pdf.extract` | Extract text from a local PDF (page-range supported) | Same roots; 256 KB cap; image-only PDFs surface an explicit "OCR required" error |
| `csv.write` | Write a CSV file (RFC 4180 quoting, optional UTF-8 BOM) | Same roots; 4 MB cap; rectangular rows enforced; atomic write |
| `tsv.write` | Write a TSV file (paste-into-spreadsheet shape) | Same roots; 4 MB cap; embedded tabs/newlines sanitised to spaces; atomic write |
| `xlsx.write` | Write a real Excel `.xlsx` workbook (multi-sheet, formulas, bold headers, freeze) via libxlsxwriter | Same roots; native Excel formulas via `=` prefix; sheet-name validation; atomic temp-then-rename |
| `xlsx.read` | Read tabular data out of a local `.xlsx` (TSV or JSON output, sheet + slice selection) via CoreXLSX | Same roots; 256 KB cap with truncation marker; missing sheet errors list available sheet names; resolves shared strings; booleans rendered as TRUE/FALSE for write↔read symmetry |
| `vault.search` | Vector + FTS retrieval over the active workspace's corpus | `topK` clamped 1-20; nil-safe when no corpus is configured |
| `wikipedia.search` | Search Wikipedia titles + bodies via the MediaWiki Action API | Returns `[{title, url, snippet, wordcount}]`; per-request `lang` arg with hostname-safety normalisation; `User-Agent` set per Wikipedia's API policy |
| `wikipedia.article` | Fetch chrome-stripped plain-text body of a Wikipedia article (`extracts` API) | 256 KB cap; missing-title surfaces a recoverable error pointing at `wikipedia.search`; optional `lead: true` for just the intro |
| `web.search` | Web search via DuckDuckGo HTML scrape (default) or SearXNG JSON (opt-in via Tools settings) | DDG parser pinned by unit tests + an external test that hits real DDG; SearXNG endpoint validated; result URLs aren't fetched (use `http.fetch` with its own allowlist) |
| `http.fetch` | HTTPS GET with strict host allowlist | Default allowlist: `en.wikipedia.org`, `raw.githubusercontent.com`; 256 KB body cap; 60 s timeout; redirects re-checked against allowlist |
| `clipboard.get` / `clipboard.set` | Read / replace the macOS clipboard | 64 KB cap on writes; `set` clears prior representations |
| `math.compute` | Arithmetic via `NSExpression` (digits, `+ - * / ( )`, scientific notation) | Whitelist regex blocks `FUNCTION:` / variable references; integer literals coerced to doubles so `1/3` returns `0.333…` not `0` |
| `builtin.quarto.render` | Render `.qmd` source to HTML/PDF/DOCX/PPTX/etc. via an external Quarto install | Streaming-tool — emits per-line stderr as live progress; output staged under `~/Library/Caches/quarto-renders/` |
| `python.run` | Run Python 3 code in a subprocess against an embedded `Python.framework` (only present when `make fetch-python` has been run; see [Plugins](#plugins)) | Per-invocation temp working dir; stdout / stderr / exit_code captured separately; default 10 s timeout, hard cap 120 s; user-account-level access (no syscall sandbox) |
| `python.eval` | Evaluate a single Python expression and return its `repr()` | Same runtime + trust model as `python.run`; expression passed via env var to avoid quoting hazards |
| `agents.handoff` / `agents.invoke` | Composition primitives — let one agent delegate to another | Inert tools; the composition driver follows the call from the trace post-segment |
| `mcp.<server>.<tool>` | Tools surfaced from external MCP servers under `~/Library/Application Support/Infer/mcp/` | Per-server consent gate (default deny); roots advertised on the server's `initialize` handshake |

Bundled agents that demonstrate these:

- **Data analyst** — `pdf.extract`, `xlsx.read`, `xlsx.write`, `csv.write`, `tsv.write`, `fs.read`, `fs.write`, `fs.list`, `math.compute`. The heavyweight tabular-data persona. Reads tables out of PDFs and spreadsheets, computes summaries via `math.compute` (no in-head arithmetic — models silently miscompute), writes results back as CSV / TSV / real `.xlsx` with formulas. Sandboxed to `~/Documents`. Use for "pull the revenue tables out of `q1-report.pdf` and produce an xlsx that aggregates by quarter."
- **Quarto renderer** — `builtin.quarto.render`. Generates `.qmd` source from a description and renders to a chosen format. See the [Quarto rendering](#quarto-rendering) section above.
- **Research assistant** — `vault.search`, `wikipedia.search`, `wikipedia.article`, `web.search`. Decision policy in the persona's system prompt: vault-first for personal-corpus questions, Wikipedia-first for encyclopedic / definitional / biographical / historical, web-search for current events / public docs. Caps at 3 tool calls per turn, cites sources inline.
- **Scratch** — `clipboard.get`, `clipboard.set`, `math.compute`, `wikipedia.search`, `wikipedia.article`, `builtin.clock.now`. Lightweight everyday assistant for short, well-scoped tasks. Caps at 1-2 tool calls per turn — the persona's value is speed. Use for "what's 0.0825 × 12 × 30?", "summarise what I just copied", "copy a polite decline email to my clipboard", "who designed the Eiffel Tower?".
- **Python coder** — `python.run`, `python.eval`, `math.compute`, `fs.read`, `builtin.clock.now`. Runs Python 3 in an embedded subprocess for calculations, parsing, and quick experiments mid-conversation. Backed by `plugin_python_tools` (requires `make fetch-python`); falls back gracefully if the framework's absent — the agent loads but `python.*` calls return errors. Default 10 s timeout per call, max 120 s. Packages baked in: `openai`, `anthropic` (override with `PY_PKGS=...`).
- **HN watcher** — `hn.search`, `hn.item`, `hn.user`. Searches Hacker News (Algolia HN API) and summarises stories, threads, or users. No setup; backed by `plugin_hacker_news`. Caps at 3 tool calls per turn; cites by `news.ycombinator.com` permalink rather than the external URL.
- **Clock assistant** — `builtin.clock.now`, `builtin.text.wordcount`. Demo for verifying tool-call plumbing on a freshly loaded model.

Authoring custom agents: drop a `*.json` file into `~/Library/Application Support/Infer/agents/`. Format mirrors the bundled agents at `projects/infer/Sources/Infer/Resources/agents/*.json` — keys: `id`, `metadata`, `requirements.toolsAllow`, `decodingParams`, `systemPrompt`.

## Settings

Open via **App menu → Settings…**, **Cmd-,**, or the **gear icon** in the chat header (next to Reset). Three tabs — set-once-and-forget configuration:

- **Tools** — Quarto executable path with live status badge, web-search backend selector (DuckDuckGo / SearXNG endpoint).
- **Plugins** — per-plugin status table; click a row to expand into per-tool descriptions and the pretty-printed `config` blob from `plugins.json`. See the [Plugins](#plugins) section below.
- **Appearance** — light / dark / system color scheme.

Mid-session knobs stay in the sidebar where they're one click away — **Model** parameters (temperature / top-p / max tokens / thinking budget / seed / system prompt with Apply) and the **Voice** tab (TTS, voice loop, dictation, whisper file transcription).

## Plugins

Compile-time, statically-linked extensions under `projects/plugins/plugin_<name>/`. Each plugin is its own SPM package depending only on the leaf `projects/plugin-api/` package — plugins cannot reach into `InferAgents` or `Infer` internals. The author surface is one protocol (`Plugin`) returning a list of `BuiltinTool` instances; the host registers them into the same `ToolRegistry` the built-in tools live in, so any persona with `requirements.toolsAllow` matching a plugin-registered tool name can call it. Plugins that need to call other tools by name (their own, built-ins, or other plugins') capture the `ToolInvoker` closure handed to `register` and dispatch through it at call time.

Whether a plugin is in the binary is decided by `projects/plugins/plugins.json`. Add an entry → `make plugins-gen` → `make build`. Remove an entry → regen → rebuild → those bytes are gone from the binary. A per-developer `projects/plugins/plugins.local.json` (gitignored) shadow-merges over the tracked file for opting out of heavy plugins locally.

Currently shipped:

| Plugin | What it adds | Setup |
|---|---|---|
| `plugin_hackernews` | `hn.search` / `hn.item` / `hn.user` against the public Algolia HN API. Pure Swift, no credentials, no install step. | None |
| `plugin_python_tools` | `python.run` (script execution) and `python.eval` (single expression) over an embedded `Python.framework` with `openai` + `anthropic` baked in | `make fetch-python` (one-time, ~5 min — builds `thirdparty/Python.framework` via `scripts/buildpy.py`). Override the package set with `PY_PKGS="openai anthropic pandas matplotlib"`. Without this step the framework is absent and `python.*` tools simply don't register — the rest of the app launches normally. |

Authoring a plugin: create `projects/plugins/plugin_<name>/` with its own `Package.swift` depending on `../../plugin-api`, conform a `public enum <Name>Plugin: Plugin` and return a `PluginContributions(tools: [...])` from `register(config:)`. Add the entry to `projects/plugins/plugins.json`, run `make plugins-gen`, rebuild. Full architecture + the reasoning behind decisions (leaf-API package, return-based contributions, why no cross-plugin deps in `plugins.json`, what shapes don't fit the plugin model) lives in `docs/dev/plugins.md`.

## Reproducibility (seed)

The Parameters sidebar section has a **Seed** row. Leave the field empty (or press Clear) for a fresh random seed per generation (default). Enter a number or press Random to pin a fixed `UInt64` seed: identical prompt + params + seed produces identical output on a given backend. Useful for A/B-ing sampler settings or debugging model behavior. Persisted across launches.

## Clean

```sh
make clean              # Remove build/
```

## Makefile Targets

| Target | Description |
|---|---|
| `build` | Build the Infer chat app via `xcodebuild` (Debug by default; override with `INFER_CONFIG=Release`) |
| `bundle` | Bundle as `build/$(INFER_CONFIG)/Infer.app` (embeds `llama.framework`, `whisper.framework`, MLX resource bundles including `default.metallib`, `AppIcon.icns`, and `WebAssets/` with KaTeX + highlight.js) |
| `run` | Bundle and open |
| `build-release` / `bundle-release` / `run-release` | Same as above but with `INFER_CONFIG=Release` — optimized bundle at `build/Release/Infer.app` |
| `test` | Fast test path — `swift test --skip ExternalTests`. Runs every suite whose name does NOT end in `ExternalTests`. Sub-3-second run; suitable for tight inner loops. |
| `test-integration` | External-system tests — `swift test --filter ExternalTests`. Runs only suites whose name ends in `ExternalTests` (e.g. `QuartoExternalTests`, which shells out to a real `quarto` binary). Each suite auto-skips per-test when its external dependency is missing, so CI hosts without Quarto / models / network stay green. |
| `test-all` | Fast + external in one pass. Useful pre-commit / pre-release. |
| `clean` | Remove `build/` |
| `clean-infer` | Remove only `build/infer-xcode` (xcodebuild derived data) |
| `clean-mlx-cache` | Remove `$HF_HOME/hub` (MLX model cache) after confirmation |
| `fetch-llama` | Download `thirdparty/llama.xcframework` (tag via `LLAMA_TAG=...`) |
| `fetch-whisper` | Download `thirdparty/whisper.xcframework` (tag via `WHISPER_TAG=...`) |
| `fetch-webassets` | Download KaTeX + highlight.js to `thirdparty/webassets/` (versions via `KATEX_VERSION=...` / `HLJS_VERSION=...`) |
| `fetch-python` | Build `thirdparty/Python.framework` via `scripts/buildpy.py` (one-time, ~5 min; opts in to `plugin_python_tools`'s `python.run` / `python.eval`). Override the bundled package set with `PY_PKGS="openai anthropic pandas matplotlib"` |
| `plugins-gen` | Regenerate plugin glue (`Package.swift` marker sections + `Sources/Infer/GeneratedPlugins.swift`) from `projects/plugins/plugins.json`. `build` depends on this so a stale `Package.swift` never reaches `xcodebuild`. Idempotent — re-running with no input change is a no-op |
| `plugins-gen-check` | CI dirty-tree assertion: regenerates and fails if anything changed. Catches "edited `plugins.json`, forgot to commit the generated diff" in review rather than at someone else's build |
| `generate-icon` | Regenerate `projects/infer/Resources/AppIcon.icns` from `scripts/generate_app_icon.swift` |
