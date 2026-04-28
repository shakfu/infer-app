# Plugin system

Status: design, unimplemented as of 2026-04-28. Supersedes the prior MCP-server-centric proposal — the centre of the design is now compile-time SwiftPM modules under `projects/plugins/plugin_<name>/`. MCP survives as one tool shape a plugin may opt into, not the architecture.

## What a "plugin" means here

A plugin is a **standalone SwiftPM package under `projects/plugins/plugin_<name>/`** that contributes some combination of tools (and, in later PRs, agents and MCP-server subprocesses) to the host app at startup. Plugins are:

- **First-party.** All plugin code lives in this repo. There is no dynamic loading, no third-party distribution, no trust tier — see "Anti-goals" below.
- **Compile-time.** Whether a plugin is in the binary is decided at build time by `projects/plugins/plugins.json`. The user can disable an included plugin at runtime via the same file (`enabled: false`) without recompiling.
- **Self-contained.** A plugin owns its own SPM dependencies, resources, and tests. Adding `plugin_foo/` plus an entry in `plugins.json` is the entire surface; nothing in the `Infer` target is hand-edited.

The plugin boundary exists for **modularity** (heavy deps stay opt-in — `plugin_python_tools` pulls in the embedded Python.framework, `plugin_wiki` pulls in a parser dep, etc.) and **optionality** (binary size and startup cost scale with what the user actually wants), not for sandboxing untrusted code.

## Layout convention

```
projects/
    plugin-api/                   # leaf SPM package; zero deps
        Package.swift
        Sources/PluginAPI/
            Plugin.swift          # Plugin, PluginContributions, PluginConfig
            PluginLoader.swift    # PluginLoader, PluginLoadResult, PluginFailureRecord
            Tool.swift            # BuiltinTool, ToolName, ToolSpec, ToolResult, ToolError, StreamingBuiltinTool, ToolEvent
        Tests/PluginAPITests/
    infer/
        Package.swift             # depends on ../plugin-api + each ../plugins/plugin_*; generator edits the marker sections inside `dependencies:` and the `Infer` target's `dependencies:`
        Sources/InferAgents/      # `@_exported import PluginAPI` so existing call sites keep working
        Sources/Infer/
            GeneratedPlugins.swift   # generator output
        ...
    plugins/
        plugins.json              # source of truth; tracked
        plugins.local.json        # optional per-dev overrides; gitignored
        plugin_wiki/
            Package.swift         # depends only on ../../plugin-api
            Sources/plugin_wiki/
                WikiPlugin.swift  # `public enum WikiPlugin: Plugin { ... }`
            Tests/plugin_wikiTests/
        plugin_python_tools/
            Package.swift
            Sources/plugin_python_tools/
                ...
        plugin_financial_analyst/
            ...
```

Each plugin is its own SPM **package** that depends only on the leaf `plugin-api` package. It does not import `InferAgents`, `Infer`, llama, MLX, or UI code — the entire surface a plugin author sees is what's in `Sources/PluginAPI/` (~150 LOC of protocols and structs).

The host's `projects/infer/Package.swift` declares each enabled plugin in two generator-managed sections:

- `// BEGIN_GENERATED_PLUGINS_PACKAGES` / `// END_GENERATED_PLUGINS_PACKAGES` inside the package-level `dependencies:` array — one `.package(path: "../plugins/plugin_<id>")` per enabled plugin.
- `// BEGIN_GENERATED_PLUGINS_PRODUCTS` / `// END_GENERATED_PLUGINS_PRODUCTS` inside the `Infer` executable target's `dependencies:` array — one `.product(name: "plugin_<id>", package: "plugin_<id>")` per enabled plugin.

Why this layout: SPM library targets are static by default, so each plugin compiles to a static library that links into the `Infer` executable at build time. The leaf `plugin-api` package breaks the package-level cycle that a flat `Infer ↔ plugin` dependency would otherwise create (Infer depends on plugin-api; each plugin depends on plugin-api; Infer depends on each plugin). Touching `Infer.swift` doesn't recompile any plugin, and touching a plugin doesn't recompile `InferAgents` — SPM's incremental cache works per package.

Each plugin's `Sources/plugin_<name>/Plugin.swift` declares one type conforming to `Plugin` (see "Plugin contract" below). Tests live next to the plugin and run on the fast path (`make test`) — they must not depend on llama/MLX/Metal.

### Naming convention

Three names per plugin, each with a distinct job. Settled, not open:

| Name              | Where it lives                          | Job                                              |
| ----------------- | --------------------------------------- | ------------------------------------------------ |
| `plugin_wiki`     | directory + SPM module + `import`       | filesystem identifier, glob-discoverable         |
| `WikiPlugin`      | the `Plugin`-conforming type inside     | Swift code at the one call site (generator file) |
| `wiki`            | `id` field in `plugins.json`, UI labels | concise user/config identifier                   |

Rules the generator enforces:

- Directory: `projects/plugins/plugin_<snake>/`. The `plugin_` prefix is structural — it's the discovery glob.
- Module name: matches the directory (`plugin_wiki`). The resulting `import plugin_wiki` is unusual for Swift but appears exactly once, in the generated `GeneratedPlugins.swift`.
- Public Plugin-conforming type: must be named `<UpperCamel(snake)>Plugin` (e.g. `WikiPlugin`, `PythonToolsPlugin`). Convention-over-config; the generator derives the Swift symbol from the directory name.
- JSON id: the snake form *without* `plugin_` (`wiki`, not `plugin_wiki`). The prefix is structural noise the user shouldn't see.

## `plugins.json` — source of truth for build and runtime

Single file. Drives both which plugins compile in and which run.

```json
{
    "plugins": [
        {
            "id": "wiki",
            "enabled": true,
            "config": { "source": "https://en.wikipedia.org" }
        },
        {
            "id": "python_tools",
            "enabled": true,
            "config": { "framework": "build/install/Python.framework" }
        },
        {
            "id": "financial_analyst",
            "enabled": false
        }
    ]
}
```

State table:

| Entry in `plugins.json` | `enabled` | In binary? | Registers at startup? |
| ----------------------- | --------- | ---------- | --------------------- |
| absent                  | —         | no         | no                    |
| present                 | `false`   | yes        | no                    |
| present                 | `true`    | yes        | yes                   |

Removing a plugin from the binary requires removing the entry and rebuilding. Toggling `enabled` is a runtime-only change (no rebuild). The `config` blob is opaque JSON passed to `Plugin.register(into:config:)`; each plugin defines and validates its own schema.

`Plugins/plugins.local.json` (gitignored) shadow-merges over `plugins.json` by `id` — same shape, present entries override, absent entries inherit. Lets a developer disable `python_tools` locally without touching tracked state.

## Build-time selection

A small Python script `scripts/gen_plugins.py` reads `plugins.json` (+ overrides) and produces two artefacts:

1. **`projects/infer/Package.swift`** — two marker-bounded sections rewritten in place:
   - `// BEGIN_GENERATED_PLUGINS_PACKAGES` / `// END_GENERATED_PLUGINS_PACKAGES` inside the package-level `dependencies:` array — one `.package(path: "../plugins/plugin_<id>")` per enabled plugin.
   - `// BEGIN_GENERATED_PLUGINS_PRODUCTS` / `// END_GENERATED_PLUGINS_PRODUCTS` inside the `Infer` executable target's `dependencies:` array — one `.product(name: "plugin_<id>", package: "plugin_<id>")` per enabled plugin.
2. **`projects/infer/Sources/Infer/GeneratedPlugins.swift`** — a `public let allPluginTypes: [any Plugin.Type] = [WikiPlugin.self, ...]` declaration plus a `public let pluginConfigs: [String: PluginConfig]` literal mirroring the `config` blobs from `plugins.json`. Imports each enabled plugin module by name.

Both files are tracked. The generator is idempotent and the marker section is the only mutated region of `Package.swift`. CI runs the generator and fails if the working tree is dirty afterwards (catches "edited `plugins.json`, forgot to regenerate").

Make integration:

```sh
make plugins-gen           # runs scripts/gen_plugins.py
make build-infer           # depends on plugins-gen
```

`build-infer` becoming dependent on `plugins-gen` means the generator runs automatically; the explicit target exists for the "I edited `plugins.json`, show me the diff before I rebuild" workflow.

**Known sharp edge:** SPM caches manifest evaluation. Editing `plugins.json` updates the generated `Package.swift` section, which itself is what SPM diffs to invalidate the cache, so the cache *is* busted correctly. Editing `plugins.local.json` without regenerating won't trigger a rebuild — the generator must run first. This is what `make plugins-gen` exists for.

## Plugin contract

Minimal — `register` returns its contributions; the host wires them into its registries. Plugins are pure declarations and `PluginAPI` stays free of host-side state.

```swift
// In the leaf `PluginAPI` module that every plugin depends on.
public protocol Plugin: Sendable {
    static var id: String { get }    // matches plugins.json id, e.g. "hackernews"
    static func register(
        config: PluginConfig,
        invoker: @escaping ToolInvoker
    ) async throws -> PluginContributions
}

public struct PluginContributions: Sendable {
    public var tools: [any BuiltinTool]
    // Future, additive: agents, RAG sources.
    public init(tools: [any BuiltinTool] = []) { self.tools = tools }
    public static let none = PluginContributions()
}

public struct PluginConfig: Sendable {
    public let json: Data
    public func decode<T: Decodable>(_ type: T.Type) throws -> T
    public static let empty: PluginConfig
}

// Cross-plugin tool dispatch. The closure dispatches against the
// host's registry as it stands at *call time*, so plugin B can capture
// it during register even when plugin A's tools register later.
public typealias ToolInvoker = @Sendable (_ name: ToolName, _ arguments: String) async throws -> ToolResult
```

`register` is the only entry point. No `start`/`stop`/`shutdown` hooks until something needs them — adding lifecycle later is cheap, making it mandatory now is what you regret. Plugins that own long-lived background work (file watcher, persistent connection) will register a teardown handle on a future `PluginContributions.teardown` field; the host drains those in `applicationWillTerminate` alongside the runner shutdown sequence.

### Cross-plugin tool dispatch

`register` is handed an `invoker: ToolInvoker` closure bound to the host's tool registry. Plugins that need to call other tools by name capture it when constructing their tools; plugins that don't need cross-tool dispatch ignore the parameter. The closure dispatches against the registry as it stands at **call time**, not register time, so plugin B can use the captured invoker to reach plugin A even when A registers later in the load order — by the time the chat turn runs and B's tool actually fires, A's tools are present.

This is what makes "a chart plugin that calls `python.run` to render plots" possible without source-level coupling between `plugin_chart` and `plugin_python_tools`. They communicate through the registry, not through each other's modules.

`PluginAPI` is the leaf SPM package at `projects/plugin-api/` — pure Swift, zero deps. `InferAgents` re-exports it via `@_exported import PluginAPI` so existing `import InferAgents` call sites continue to see `BuiltinTool`, `ToolName`, etc., unchanged.

### Failure during register

A throwing `register` does **not** abort startup. `PluginLoader.loadAll` catches per-plugin, records a `PluginFailureRecord`, and continues with the remaining plugins. The host logs each failure at ERROR and (in a later PR) surfaces it in two visible places: a non-dismissable banner the first time the user opens the chat, and a red-status row in Settings → Plugins.

```swift
let invoker: ToolInvoker = { name, args in
    try await registry.invoke(name: name, arguments: args)
}
let result = await PluginLoader.loadAll(
    types: allPluginTypes,
    configs: pluginConfigs,
    invoker: invoker
)
for (id, contrib) in result.contributions {
    for tool in contrib.tools { await registry.register(tool) }
}
for failure in result.failures {
    logger.error("plugin \(failure.pluginID) failed to register: \(failure.message)")
}
```

Reasoning: plugin failures are realistic (missing artefact, bad config blob, network warmup), and "app won't launch because the wiki plugin's URL is malformed" is a UX cliff for a small bug. The risk of catch-and-log is silent degradation — mitigated by surfacing the failure in two visible places, not just logs.

### Config validation

Per-plugin config is validated **at register time, not build time**. The plugin decodes its own config:

```swift
public static func register(
    config: PluginConfig,
    invoker _: ToolInvoker
) async throws -> PluginContributions {
    let cfg = try config.decode(MyConfig.self)
    // ...
}
```

A decode failure throws and falls into the failure-during-register handler above. The user sees a banner saying "wiki plugin failed: missing required key 'source'" at first launch — the same diagnostic a build-time JSON Schema would give, just one launch later.

No JSON Schema files, no `jsonschema` dependency in `gen_plugins.py`. The cost (write a schema per plugin, keep it in sync with the Swift `Codable` struct, introduce schema-vs-struct drift as a new failure mode) outweighs the benefit at this scale. Revisit when one of (a) more than five plugins exist, (b) configs get complex enough that decode errors are confusing, (c) a Settings UI wants typed forms.

## What a plugin can contribute

- **Tools** — `PluginContributions(tools: [WikiSearchTool()])`. Standard `BuiltinTool` conformance from `PluginAPI`; no plugin-specific tool protocol.
- **(Future) Agents** — `PluginContributions.agents` will hold `[any Agent]`. The `agents.md` precedence rule (user-JSON > plugin > first-party) holds; with all-in-tree plugins, this is descriptive (it tells you where an agent came from) rather than a runtime trust boundary. Lands when an agent-shipping plugin needs it.
- **MCP servers** — *not via plugins.* MCP integration lives in the host's `MCPHost` (`projects/infer/Sources/InferAgents/MCP/`), configured at runtime via `~/Library/Application Support/Infer/mcp/*.json`. Each server's tools register into the same `ToolRegistry` plugins write to, namespaced as `mcp.<server>.<tool>`. The LLM can't tell the difference between a plugin-contributed tool and an MCP-surfaced one — both look identical in the system-prompt tool list and dispatch through `ToolRegistry.invoke`. Building "plugin spawns MCP subprocess" was considered and dropped: it would duplicate `MCPHost`'s job for marginal benefit (the only thing it'd add is *compile-time-fixed* MCP server choice, which fights MCP's runtime-configurable shape).
- **(Future) RAG sources, UI extensions** — additive fields on `PluginContributions`; not in v1.

## Worked examples

Sketches only — exact tool/agent shapes will fall out of the implementation.

**`plugin_wiki`** — registers a `WikiAgent` (persona-style) plus a `wiki.search` tool. Pure Swift, no heavy deps. Likely depends on `swift-markdown` (already in the workspace) for parsing fetched articles. `config.source` selects the wiki endpoint.

**`plugin_python_tools`** — registers `python.run` and `python.eval` tools backed by the embedded Python.framework that `scripts/buildpy.py -i openai -c framework_max` produces. Declares the framework as an SPM `binaryTarget` and the `config.framework` path resolves to it. The whole point of conditional compilation: a build without this plugin doesn't ship Python.

**`plugin_financial_analyst`** — registers a `FinancialAnalystAgent` (composed of generalist + a `yahoo.quote` tool + a `csv.read` tool, per `agent_composition.md`). Light deps. Mostly a worked example of "an agent + a couple of tools is a plugin."

## Consent model

Carries over from the prior design — plugin code is first-party but the model is an unreliable agent inside a trusted app, so real-world side effects need human authorisation:

- **Default-disabled.** A plugin entry with `enabled: false` is the default ship state for anything that touches the network or filesystem.
- **Per-tool consent.** Every tool call prompts unless the user has ticked "always allow this tool." Consent is scoped to `(plugin_id, tool_name)`.
- **Argument preview, no truncation.** The consent prompt shows the full JSON arguments. Hiding args to fit a dialog is how users approve `rm -rf $HOME`.
- **Tool output is model-visible input.** Tool results render with the same escaping the assistant channel uses; the threat model is a malicious *document the tool fetched* injecting instructions into the model, not the tool itself.

The consent UI ships as a single `Alert` with **Allow once / Allow for this turn / Deny**. Persistent "always allow" lands later.

## Dependencies between plugins

**Host → plugin: by design.** The generator-managed marker section in `Infer/Package.swift` adds `.package(path:)` + `.product(...)` for every enabled plugin. The host depends on each enabled plugin via SPM. Disabling a plugin in `plugins.json` removes it from the build dep.

**Plugin → plugin: technically supported, architecturally discouraged.** SPM allows it (plugin_b's `Package.swift` adds `.package(path: "../plugin_a")` and imports `plugin_a`), but it creates an implicit ordering/inclusion requirement that `plugins.json` doesn't capture: enabling `plugin_b` without `plugin_a` becomes a compile-time break. Two plugins coupling at the source level usually means there's a third concept that wants its own SPM package — extract it to `projects/plugin-utils/` (or whatever fits the abstraction) and have both plugins depend on the utility, not on each other.

**The recommended pattern for cross-plugin tool composition:** plugin B's tool dispatches plugin A's tool **at runtime, by name through the host's `ToolRegistry`** — not by importing A's module. This requires extending `BuiltinTool` to optionally receive a `ToolInvoker` closure (so a tool can call `invoker("python.run", ...)` without holding the registry actor). Not built today; lands the first time a real cross-plugin call appears.

**Host hard-depending on a specific plugin: don't.** If the host can't function without `plugin_X`, then `plugin_X` isn't really optional — it's a host feature that happens to live in a plugin directory. Move it into `Sources/Infer/`. The plugin boundary exists for **optional** contributions only.

### Should `plugins.json` declare dependencies?

**No today.** `plugins.json` lists *which plugins exist* in the build; it is not a static dependency graph. The two flavors of cross-plugin dep are handled by other mechanisms:

- **Source-level deps** (plugin B `import`s plugin A's module) are an architectural smell — extract the shared code into a third package and have both depend on it. SPM's compile-time error if the dep is missing is clearer than anything a JSON validator would print, so there's nothing for `plugins.json` to add.
- **Runtime tool-call deps** (plugin B's tool dispatches `python.run` by name) are loose by nature — B's tool can fall back when A isn't loaded. Declaring this as a hard `dependencies` field misrepresents the relationship. (When `BuiltinTool` gains a `ToolInvoker` and the first cross-plugin call ships, a soft `recommends:` field may be worth adding.)
- **External-system / system-resource deps** (`Python.framework`, a CLI tool on PATH, an environment variable) are validated by the plugin's own `register` and surfaced through the existing `PluginFailureRecord` path. A plugin's `register` throwing `frameworkNotFound` is more precise than a static `requires_external: ["python"]` declaration could be — `register` knows where to look and what to suggest.

**Revisit when** a real plugin ships that's genuinely useless without another (`plugin_chart` requiring `plugin_python_tools` is the canonical hypothetical). Right shape at that point: a soft `requires: ["python_tools"]` field that emits a *warning* via `PluginFailureRecord` if the listed plugin isn't enabled — not a build-time gate, not a hard refuse-to-load. Hard requirements between plugins should make you reconsider whether the two are really one plugin.

## Anti-goals

- **No dynamic plugin loading.** No `Bundle.load`, no `.dylib` discovery, no third-party plugin authors. The plugin boundary is source organisation + a build-time toggle, not a sandbox. Revisit only when a concrete third-party plugin exists and its author asks for it. (Cost detail in the prior version of this doc — `-enable-library-evolution`, signing/notarisation, frozen `Plugin` API surface — none hard, all premature.)
- **No third-party plugin distribution.** Not a marketplace, not a `plugins.json` pointing at random binaries. Contributions happen via the repo.
- **No runtime plugin discovery.** The set of plugins in the binary is fixed at build time. Adding a plugin is a code change.
- **No cross-platform plugin API.** Infer is macOS-only; the API can assume POSIX, `Process`, and Apple frameworks.
- **No abstraction over MCP.** If a plugin uses MCP, it talks MCP. Wrapping it in an Infer-flavoured protocol just to "keep options open" adds maintenance without buying anything.
- **Tool calls are not the default.** A user with no plugins enabled (or no plugins built in) sees zero behavioural change — no extra system-prompt text, no latency, no UI affordance.

## PR-A (landed) — substrate + placeholder

Substrate built and exercised end-to-end via a placeholder `plugin_wiki`:

- `projects/plugin-api/` SPM package — `Plugin`, `PluginContributions`, `PluginConfig`, `PluginLoader`, plus tool primitives (`BuiltinTool`, `ToolName`, `ToolSpec`, `ToolResult`, `ToolError`, `StreamingBuiltinTool`, `ToolEvent`).
- `projects/plugins/plugins.json` with one entry; `scripts/gen_plugins.py`; `make plugins-gen`; `make plugins-gen-check` for CI dirty-tree assertion.
- `projects/plugins/plugin_wiki/` placeholder — its own `Package.swift`, depends only on `../../plugin-api`. Registers one no-op tool (`wiki.ping`) so the substrate has a real consumer. PR-B (next) replaces this with the wiki-per-`docs/dev/wiki.md` implementation.
- Tool primitives moved out of `InferAgents`; `@_exported import PluginAPI` keeps existing call sites unchanged. `ToolRegistry` stays in `InferAgents` (host-side state, not plugin-facing surface).
- `Infer` target reads `GeneratedPlugins.swift` in `bootstrapAgents`, calls `PluginLoader.loadAll`, registers contributions into the existing `ToolRegistry`, logs failures.
- Tests: `PluginAPITests` (loader + config), `plugin_wikiTests` (placeholder smoke). `make test` runs all three packages' suites.

## Landed since PR-A

- **`plugin_python_tools`** — `python.run` + `python.eval` over the embedded `Python.framework` built by `scripts/buildpy.py`. Subprocess model (no in-process libpython linkage), per-invocation temp working dir, default 10 s / max 120 s timeout. Framework discovery: `config.python_path` → app-bundle Frameworks → repo `thirdparty/Python.framework`. Bundle rule (`make bundle`) copies the framework into `Infer.app/Contents/Frameworks/` if present. 7 fast-path unit + 7 `PythonExternalTests` (auto-skip when framework absent).
- **Cross-plugin tool dispatch.** `Plugin.register` extended with an `invoker: ToolInvoker` parameter; `ToolInvoker` moved out of `InferAgents` into `PluginAPI`. The closure dispatches at call time, not register time, so plugin B's tool can call plugin A's tool by name even though A's tools weren't in the registry when B's `register` ran.
- **Settings window** (Cmd-, / App menu / cog icon in chat header). Five tabs: Model parameters, Voice, Tools, Plugins, Appearance. Sidebar trimmed to navigation only (Model picker, Agents, History, Console). Stale `tabRaw` values for removed sidebar tabs fall through to `.model`.
- **Plugins-tab detail view.** Expandable rows; full per-tool descriptions; pretty-printed config blob from `plugins.json`; Reveal-in-Finder. Read-only — editing config in-app waits for the runtime toggle (next item) to land.

## Roadmap (subsequent PRs, rough order)

- **PR-C:** Runtime `enabled` toggle + `plugins.local.json` override merge. Currently the build-time-only `enabled: false` requires a rebuild. Runtime toggle adds a per-user state file (NOT `plugins.json`) and a switch in the Plugins detail view; takes effect on next launch since `register` only runs at startup.
- **PR-E:** `plugin_financial_analyst` — drives out the "plugin ships a composed agent" path against `agent_composition.md`. Adds `PluginContributions.agents`.
- **PR-G:** Persistent "always allow" consent (per `(plugin_id, tool_name)`), backed by a separate state file (not `plugins.json` — that's build/enable, this is per-user trust).
- **PR-H:** Editable per-plugin config in the Settings detail view. Depends on PR-C (otherwise edits would force a rebuild every time).

PR-B (real wiki plugin) and PR-F (MCP subprocess plugin) were both **dropped**:
- The wiki belongs in the host (vault co-residency, FTS atomicity with conversations, workspace cascade) — see `docs/dev/wiki.md` for the unchanged design, owned by the host now.
- MCP integration already lives in `MCPHost`; building a parallel plugin-API path for it would duplicate the same job for marginal benefit. See "What a plugin can contribute" above.

## Open questions

- **Generator source-of-truth check in CI.** A dirty-tree assertion catches the "edited JSON, forgot to regen" case. Does it also need to catch "edited a plugin's `Package.swift` file by hand inside the generated section"? Probably yes — markers + checksum.
