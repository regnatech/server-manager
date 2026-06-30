#!/usr/bin/env python3
"""server-manager MCP server.

A Model Context Protocol server (JSON-RPC 2.0 over stdio) that lets an AI assistant
drive server-manager — listing sites/servers, reading metrics/logs/audits, and
(optionally) deploying, rolling back, scaling workers, toggling the scheduler and
editing the .env on the managed servers.

It is a thin wrapper: every tool shells out to `server --json <args>` and parses
the NDJSON event stream, so it inherits the exact behaviour of the CLI.

Safety:
  * Read-only tools are always available.
  * Mutating tools (deploy/rollback/ssl/scheduler/worker scale/env set) are only
    exposed when SM_MCP_ALLOW_WRITE=1.
  * Reading the .env (which contains secrets) requires SM_MCP_ALLOW_SECRETS=1.

Stdlib only — no third-party packages.
"""

import json
import os
import shutil
import subprocess
import sys

SERVER_BIN = os.environ.get("SM_BIN") or shutil.which("server") or "server"
ALLOW_WRITE = os.environ.get("SM_MCP_ALLOW_WRITE") == "1"
ALLOW_SECRETS = os.environ.get("SM_MCP_ALLOW_SECRETS") == "1"

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "server-manager", "version": "0.1.0"}


def log(*a):
    """Diagnostics go to stderr so stdout stays a clean protocol channel."""
    print("[server-manager-mcp]", *a, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# Running the CLI
# --------------------------------------------------------------------------

def run_server(args, timeout=120):
    """Run `server --json <args>` and parse its NDJSON output.

    Returns a dict: {ok, data, report, messages, steps, raw} suitable for
    returning straight to the model.
    """
    cmd = [SERVER_BIN, "--json", *args]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
    except FileNotFoundError:
        return {"ok": False, "error": f"`server` CLI not found at {SERVER_BIN!r}"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"timed out after {timeout}s: {' '.join(cmd)}"}

    out = {
        "ok": proc.returncode == 0,
        "exit_code": proc.returncode,
        "data": [],
        "report": None,
        "messages": [],
        "steps": [],
    }
    noise = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            noise.append(line)
            continue
        t = ev.get("t")
        if t == "data":
            out["data"].append({k: v for k, v in ev.items() if k != "t"})
        elif t == "report":
            out["report"] = {"title": ev.get("title"), "fields": ev.get("fields")}
        elif t == "step_end":
            out["steps"].append({"label": ev.get("id"), "ok": ev.get("ok"), "err": ev.get("err")})
        elif t == "log" and ev.get("level") in ("warn", "err"):
            out["messages"].append(f"{ev.get('level')}: {ev.get('msg')}")
        elif t == "done":
            out["ok"] = bool(ev.get("ok"))
    stderr = proc.stderr.strip()
    if stderr:
        noise.append(stderr)
    if noise:
        out["raw"] = "\n".join(noise)[:4000]
    return out


def result_text(res):
    """Render a run_server() result as compact, model-friendly JSON text."""
    return json.dumps(res, indent=2, ensure_ascii=False)


# --------------------------------------------------------------------------
# Tools
# --------------------------------------------------------------------------
# Each tool: name -> {description, schema, build(args)->cli_args, timeout, write, secret}

def _req(*names):
    return list(names)


TOOLS = {
    "list_sites": {
        "description": "List all managed sites with framework, TLS and last deploy.",
        "schema": {"type": "object", "properties": {}},
        "build": lambda a: ["list"],
    },
    "list_servers": {
        "description": "List the registered target servers.",
        "schema": {"type": "object", "properties": {}},
        "build": lambda a: ["servers"],
    },
    "metrics": {
        "description": "Health snapshot of a server (CPU, memory, disk, load, services).",
        "schema": {"type": "object", "properties": {
            "server": {"type": "string", "description": "Server name (optional; default server if omitted)."}}},
        "build": lambda a: ["metrics"] + (["--server", a["server"]] if a.get("server") else []),
    },
    "uptime": {
        "description": "HTTP health check for all sites (status code, response time, up/down).",
        "schema": {"type": "object", "properties": {}},
        "build": lambda a: ["uptime", "--all"],
    },
    "logs": {
        "description": "Tail a site's remote logs.",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"},
            "type": {"type": "string", "enum": ["nginx", "php", "laravel", "queue"]},
            "lines": {"type": "integer", "default": 200}},
            "required": ["domain"]},
        "build": lambda a: ["logs", a["domain"]] + ([a["type"]] if a.get("type") else []) + ["-n", str(a.get("lines", 200))],
    },
    "audit": {
        "description": "Security audit findings for the server (and a site if given).",
        "schema": {"type": "object", "properties": {"domain": {"type": "string"}}},
        "build": lambda a: ["audit"] + ([a["domain"]] if a.get("domain") else []),
    },

    # ---- write tools (require SM_MCP_ALLOW_WRITE=1) -----------------------
    "deploy": {
        "write": True, "timeout": 1800,
        "description": "Deploy a site (intelligent zero-downtime update: pull, build, migrate, restart).",
        "schema": {"type": "object", "properties": {"domain": {"type": "string"}}, "required": ["domain"]},
        "build": lambda a: ["update", a["domain"]],
    },
    "rollback": {
        "write": True, "timeout": 600,
        "description": "Roll a site back to its previous deploy (code + data).",
        "schema": {"type": "object", "properties": {"domain": {"type": "string"}}, "required": ["domain"]},
        "build": lambda a: ["rollback", a["domain"]],
    },
    "renew_tls": {
        "write": True, "timeout": 300,
        "description": "Issue or renew a site's Let's Encrypt certificate.",
        "schema": {"type": "object", "properties": {"domain": {"type": "string"}}, "required": ["domain"]},
        "build": lambda a: ["ssl", a["domain"]],
    },
    "scheduler": {
        "write": True,
        "description": "Enable or disable the Laravel scheduler for a site.",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"},
            "action": {"type": "string", "enum": ["on", "off", "status"]}},
            "required": ["domain", "action"]},
        "build": lambda a: ["scheduler", a["domain"], a["action"]],
    },
    "worker_scale": {
        "write": True,
        "description": "Set how many worker processes run in parallel for a site.",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"},
            "count": {"type": "integer", "minimum": 1}},
            "required": ["domain", "count"]},
        "build": lambda a: ["worker", a["domain"], "scale", str(a["count"])],
    },
    "env_get": {
        "write": True, "secret": True,
        "description": "Read one .env value of a site (sensitive).",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"}, "key": {"type": "string"}},
            "required": ["domain", "key"]},
        "build": lambda a: ["env", a["domain"], "get", a["key"]],
    },
    "env_set": {
        "write": True, "secret": True,
        "description": "Set one .env value of a site (saved on the remote).",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"}, "key": {"type": "string"}, "value": {"type": "string"}},
            "required": ["domain", "key", "value"]},
        "build": lambda a: ["env", a["domain"], "set", a["key"], a["value"]],
    },
}


def available_tools():
    out = {}
    for name, t in TOOLS.items():
        if t.get("write") and not ALLOW_WRITE:
            continue
        if t.get("secret") and not ALLOW_SECRETS:
            continue
        out[name] = t
    return out


# --------------------------------------------------------------------------
# JSON-RPC plumbing
# --------------------------------------------------------------------------

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def reply(req_id, result):
    send({"jsonrpc": "2.0", "id": req_id, "result": result})


def error(req_id, code, message):
    send({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}})


def handle(req):
    method = req.get("method")
    req_id = req.get("id")
    params = req.get("params") or {}

    # Notifications (no id) — acknowledge by doing nothing.
    if req_id is None:
        return

    if method == "initialize":
        reply(req_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        })
    elif method == "ping":
        reply(req_id, {})
    elif method == "tools/list":
        tools = [
            {"name": n, "description": t["description"], "inputSchema": t["schema"]}
            for n, t in available_tools().items()
        ]
        reply(req_id, {"tools": tools})
    elif method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        tools = available_tools()
        if name not in tools:
            reply(req_id, {
                "content": [{"type": "text", "text":
                    f"Tool {name!r} is not available. "
                    f"(Mutating tools need SM_MCP_ALLOW_WRITE=1; secret tools need SM_MCP_ALLOW_SECRETS=1.)"}],
                "isError": True,
            })
            return
        spec = tools[name]
        try:
            cli_args = spec["build"](args)
        except KeyError as e:
            reply(req_id, {"content": [{"type": "text", "text": f"Missing argument: {e}"}], "isError": True})
            return
        res = run_server(cli_args, timeout=spec.get("timeout", 120))
        reply(req_id, {
            "content": [{"type": "text", "text": result_text(res)}],
            "isError": not res.get("ok", False),
        })
    else:
        error(req_id, -32601, f"Method not found: {method}")


def main():
    log(f"ready (bin={SERVER_BIN}, write={'on' if ALLOW_WRITE else 'off'}, "
        f"secrets={'on' if ALLOW_SECRETS else 'off'})")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        try:
            handle(req)
        except Exception as e:  # never crash the loop
            log("error handling request:", e)
            rid = req.get("id") if isinstance(req, dict) else None
            if rid is not None:
                error(rid, -32603, f"internal error: {e}")


if __name__ == "__main__":
    main()
