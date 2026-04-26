# MCP server configuration

Infer talks to [Model Context Protocol](https://modelcontextprotocol.io) servers
over stdio. Each server is described by one JSON file under
`~/Library/Application Support/Infer/mcp/`. The file's basename is the
server's stable id (so `slack.json` registers as `slack` and exposes its tools
as `mcp.slack.<tool>`).

This document covers the schema, the lifecycle, and the consent / roots model.
For the in-app surface, see the **Agents → MCP servers** section in the
sidebar.

## Where configs live

```
~/Library/Application Support/Infer/mcp/
├── filesystem.json
├── github.json
└── sqlite.json
```

Click **Reveal folder** in the MCP servers section of the Agents tab to land
here. Click **Reload** after editing to re-scan and re-launch approved
servers without restarting the app.

Examples ready to copy: `docs/examples/mcp/{filesystem,github,sqlite}.json` in
this repo.

## Schema

```jsonc
{
  "id": "slack",                       // required. stable identifier; basename
                                       // of the file is the canonical source.
  "displayName": "Slack",              // optional. shown in the UI; defaults to id.
  "command": "node",                   // required. executable name (PATH-resolved)
                                       // or absolute path.
  "args": ["server.js", "--ws=acme"],  // optional. argv passed to the subprocess.
  "env": { "SLACK_TOKEN": "xoxb-…" },  // optional. process env. nil = inherit.
  "enabled": true,                     // optional, default true. set false to
                                       // keep the file but skip launching.
  "autoApprove": false,                // optional, default false. set true to
                                       // bypass the consent gate (for first-
                                       // party / locally-authored configs).
  "roots": ["~/Documents/work"]        // optional, default []. filesystem
                                       // scope advertised to the server via
                                       // the MCP `roots` capability. paths
                                       // are tilde-expanded and normalised
                                       // to file:// URIs.
}
```

Every field except `id` and `command` is optional. Pre-existing minimal
configs continue to work — `autoApprove` and `roots` default to safe values
(gate enabled, no advertised scope).

## Lifecycle

1. **Discovery** — at app start (`bootstrapAgents`) and on every Reload, the
   host scans the directory for `*.json` and decodes each one through
   `MCPServerConfig`.
2. **Consent gate** — for each `enabled: true` server, the `MCPApprovalProvider`
   is consulted. The default provider:
   - returns `.allowOnce` when `autoApprove: true`, OR when the server id is
     in the `MCPApprovalStore` (UserDefaults under `mcp.approvedServers`);
   - returns `.deny` otherwise.
3. **Launch** — `StdioMCPTransport` spawns the subprocess and `MCPClient` runs
   the `initialize` handshake → `tools/list` → caches the tool catalogue.
4. **Registration** — each discovered tool is wrapped as an `MCPBuiltinTool`
   adapter and registered into the host's `ToolRegistry` under the name
   `mcp.<serverID>.<toolName>`. Agent-side tool gating
   (`requirements.toolsAllow` / `toolsDeny`) works unchanged.
5. **Inbound** — the client responds to `roots/list` requests from the server
   with the configured roots. Other inbound methods get a JSON-RPC `-32601`
   "method not found" so non-conformant servers don't hang.
6. **Shutdown** — `applicationWillTerminate` shuts down every running client
   so child processes don't outlive the app.

Each step's failures are surfaced as `MCPLoadDiagnostic`s in the Agents tab
banner and to Console. Failures don't abort the rest of the bootstrap — one
broken server doesn't blackhole the others.

## Consent model

Two layers, in order:

1. **Per-server consent** (this file). `autoApprove` or `MCPApprovalStore`
   approval; controls whether the subprocess launches at all.
2. **Per-agent tool allow/deny** (in the agent's JSON). Once a server's tools
   are registered, agents still filter via `requirements.toolsAllow` /
   `toolsDeny`. An agent with `toolsAllow: ["mcp.filesystem.read"]` won't
   accidentally call `mcp.github.create_issue` even if both servers are
   approved.

A future `gate` composition primitive will add a third layer: per-call
approval for sensitive tools regardless of source. Until then, the per-server
gate is the load-bearing security boundary.

## Roots

The `roots` field tells the server what filesystem scope it should operate
on, via the MCP `roots` capability advertised in the initialize handshake
and answered on inbound `roots/list` requests.

**Important caveat**: roots are a protocol-level signal, not OS-level
enforcement. A well-behaved server respects the list; a non-conformant
server can ignore it and access anything the parent process can. That's
why the consent gate runs first — approval is the load-bearing decision;
roots narrow what an approved server *should* do.

## Real-world commands

Popular Anthropic-published servers (from `@modelcontextprotocol`):

| Purpose      | Command                                                              |
|--------------|----------------------------------------------------------------------|
| Filesystem   | `npx -y @modelcontextprotocol/server-filesystem /path/to/dir`        |
| GitHub       | `npx -y @modelcontextprotocol/server-github` (env: `GITHUB_TOKEN`)   |
| SQLite       | `uvx mcp-server-sqlite --db-path /path/to/db.sqlite`                 |
| Brave search | `npx -y @modelcontextprotocol/server-brave-search` (env: API key)    |
| Memory       | `npx -y @modelcontextprotocol/server-memory`                         |

`npx -y` and `uvx` mean the user doesn't need to pre-install the server —
the package manager fetches it on first launch. That comes with a startup
latency cost; for production workflows, install the binary and use an
absolute path in `command`.

## Debugging

- **Server failed to launch**: check Console (`mcp` source) for the launch
  error. Common causes: command not on PATH, `npx`/`uvx` not installed, env
  var typo.
- **Server initialized but exposed no tools**: the `tools/list` call
  succeeded but returned `[]`. Either the server has no tools (some are
  resources-only, which Infer doesn't yet support) or it's mis-configured
  (wrong CLI flags, missing env).
- **Server stderr is chatty**: each line lands in Console under
  `mcp.stderr`. Useful for diagnosing auth failures or startup races that
  don't surface as a hard launch error.
- **Per-tool latency**: shown in the assistant message's trace disclosure
  (the `TelemetryBadge` chip). Slow MCP tools dominate turn time and are
  the first thing to look at when responses feel sluggish.

## What's not here yet

Tracked in `TODO.md` under "P3 — MCP follow-ups":

- MCP **resources** capability (servers exposing readable URIs)
- MCP **prompts** capability (server-curated prompt templates)
- MCP **sampling** capability (server-initiated LLM calls through the host)
- **HTTP / WebSocket** transports (stdio only for now)
- **Hot-reload** (config-file watcher; today it's manual via the Reload
  button)
- **In-app config editing** (today configs are authored in JSON files; the
  UI is read+approve, not write)
