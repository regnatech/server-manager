# server-manager — MCP server

`server mcp` runs a [Model Context Protocol](https://modelcontextprotocol.io)
server so an AI assistant (Claude Desktop, Claude Code, etc.) can drive
server-manager — **the whole CLI**: list sites/servers, read metrics/logs/audits,
deploy, roll back, manage TLS/scheduler/workers/cron, edit files and the `.env`,
run git operations, import/export databases, and more.

It's a thin wrapper: every tool shells out to `server --json <args>` and parses
the NDJSON stream, so it behaves exactly like the CLI. JSON-RPC 2.0 over stdio.

## Requirements

`python3` (standard library only — no pip packages) on the machine that runs the
CLI. The MCP server runs *locally* and reaches the managed servers over SSH, just
like the CLI.

## Permission model

Write operations are **available** so the AI can actually manage your servers —
the permission is the **MCP client's per-call approval**: Claude asks you to
confirm each tool call before it runs. Tune it with env vars:

| Env var | Effect |
|---|---|
| *(none)* | Read + write tools exposed; you approve each call in the client. |
| `SM_MCP_READONLY=1` | Hard-disable every mutating tool (observe-only). |
| `SM_MCP_ALLOW_SECRETS=1` | Also expose `.env` reads (`env_get`, `env_show`) — these send secret values to the model, so they're opt-in. |

## Tools

Curated tools cover the common operations with proper schemas:

- **Read:** `list_sites`, `list_servers`, `metrics`, `uptime`, `logs`, `audit`,
  `diff`, `config_get`, `help`
- **Write** (hidden under `SM_MCP_READONLY`): `deploy`, `rollback`, `renew_tls`,
  `scheduler`, `worker_scale`, `add_site`, `import_site`, `release`, `php`,
  `db_import`, `db_export`, `cron`, `audit_fix`, `git`, `upload`, `env_set`,
  `env_unset`, `config_set`, `connect_server`, `use_server`
- **Secrets** (need `SM_MCP_ALLOW_SECRETS=1`): `env_get`, `env_show`

…and an escape hatch covering **everything else**:

- **`run`** — run any `server` subcommand directly, e.g.
  `{"args": ["update", "clicketta.net"]}`. Use `help` to discover commands.
  (Interactive commands like `ui` are refused.)

## Configure your MCP client

**Claude Code**

```bash
# Writes enabled, approved per call in the client:
claude mcp add server-manager -- server mcp

# Observe-only:
claude mcp add server-manager --env SM_MCP_READONLY=1 -- server mcp
```

**Claude Desktop** — add to `claude_desktop_config.json`:

```jsonc
{
  "mcpServers": {
    "server-manager": {
      "command": "server",
      "args": ["mcp"],
      "env": {
        // "SM_MCP_READONLY": "1",        // uncomment for observe-only
        // "SM_MCP_ALLOW_SECRETS": "1"    // uncomment to allow reading .env values
      }
    }
  }
}
```

If `server` isn't on the client's PATH, use the absolute path to `bin/server`.

## Try it manually

The server speaks newline-delimited JSON-RPC on stdio:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_sites","arguments":{}}}' \
  | server mcp
```

## Safety notes

- The assistant acts with the same authority as your CLI (root / sudo on the
  managed servers). Keep your MCP client's per-call approval on, and only grant
  it for assistants and contexts you trust.
- Use `SM_MCP_READONLY=1` when you just want the AI to observe.
- `.env` reads are off by default so secrets aren't sent to the model unasked.
