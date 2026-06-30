# server-manager — MCP server

`server mcp` runs a [Model Context Protocol](https://modelcontextprotocol.io)
server so an AI assistant (Claude Desktop, Claude Code, etc.) can drive
server-manager: list sites/servers, read metrics/logs/audits, and — when you
allow it — deploy, roll back, renew TLS, toggle the scheduler, scale workers and
edit the `.env`.

It's a thin wrapper: every tool shells out to `server --json <args>` and parses
the NDJSON stream, so it behaves exactly like the CLI. JSON-RPC 2.0 over stdio.

## Requirements

`python3` (standard library only — no pip packages) on the machine that runs the
CLI. The MCP server runs *locally* and reaches the managed servers over SSH, just
like the CLI.

## Tools

**Read-only (always available)**

| Tool | What it does |
|---|---|
| `list_sites` | All managed sites (framework, TLS, last deploy) |
| `list_servers` | Registered target servers |
| `metrics` | CPU/memory/disk/load/services for a server |
| `uptime` | HTTP health check for every site |
| `logs` | Tail a site's logs (`nginx`/`php`/`laravel`/`queue`) |
| `audit` | Security audit findings |

**Mutating — only with `SM_MCP_ALLOW_WRITE=1`**

`deploy`, `rollback`, `renew_tls`, `scheduler` (on/off), `worker_scale`.

**Secrets — only with `SM_MCP_ALLOW_SECRETS=1`**

`env_get`, `env_set` (the `.env` holds credentials).

By default only the read-only tools are exposed, so an assistant can observe but
not change anything until you opt in.

## Configure your MCP client

**Claude Desktop** — add to `claude_desktop_config.json`:

```jsonc
{
  "mcpServers": {
    "server-manager": {
      "command": "server",
      "args": ["mcp"],
      "env": {
        "SM_MCP_ALLOW_WRITE": "1",      // omit to keep it read-only
        "SM_MCP_ALLOW_SECRETS": "1"     // omit to hide .env values
      }
    }
  }
}
```

If `server` isn't on the client's PATH, use the absolute path to `bin/server`
(or to `mcp/server_manager_mcp.py` run via `python3`).

**Claude Code** — register it once:

```bash
claude mcp add server-manager -- server mcp
# read-only by default; to allow changes:
claude mcp add server-manager --env SM_MCP_ALLOW_WRITE=1 -- server mcp
```

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

- Mutating and secret tools are **off by default**; enable them deliberately.
- The assistant acts with the same authority as your CLI (root / sudo on the
  managed servers). Only enable write access for assistants and contexts you
  trust.
