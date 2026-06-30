#!/usr/bin/env python3
"""server-manager MCP server.

A Model Context Protocol server (JSON-RPC 2.0 over stdio) that lets an AI assistant
drive server-manager — listing sites/servers, reading metrics/logs/audits, and
(optionally) deploying, rolling back, scaling workers, toggling the scheduler and
editing the .env on the managed servers.

It is a thin wrapper: every tool shells out to `server --json <args>` and parses
the NDJSON event stream, so it inherits the exact behaviour of the CLI.

Permission model:
  * Read and write tools are both exposed by default. The AI can request a write
    (deploy/rollback/ssl/scheduler/worker scale/env set), and the MCP client asks
    you to approve each call — that per-call approval IS the permission.
  * SM_MCP_READONLY=1 hard-disables every mutating tool server-side (kill switch).
  * Reading existing .env values (env_get) leaks secrets to the model, so it is
    opt-in: SM_MCP_ALLOW_SECRETS=1.

Stdlib only — no third-party packages.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

SERVER_BIN = os.environ.get("SM_BIN") or shutil.which("server") or "server"
READONLY = os.environ.get("SM_MCP_READONLY") == "1"
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


def run_help(timeout=15):
    """Capture `server help` (usage prints to stderr, not as JSON)."""
    try:
        proc = subprocess.run([SERVER_BIN, "help"], capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        return {"ok": False, "error": str(e)}
    return {"ok": True, "help": (proc.stdout + proc.stderr).strip()}


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
        "secret": True,
        "description": "Read one .env value of a site (sensitive — exposes the secret to the model).",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"}, "key": {"type": "string"}},
            "required": ["domain", "key"]},
        "build": lambda a: ["env", a["domain"], "get", a["key"]],
    },
    "env_show": {
        "secret": True,
        "description": "Show a site's whole .env (sensitive — exposes all secrets to the model).",
        "schema": {"type": "object", "properties": {"domain": {"type": "string"}}, "required": ["domain"]},
        "build": lambda a: ["env", a["domain"], "show"],
    },
    "env_set": {
        "write": True,
        "description": "Set one .env value of a site (saved on the remote).",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"}, "key": {"type": "string"}, "value": {"type": "string"}},
            "required": ["domain", "key", "value"]},
        "build": lambda a: ["env", a["domain"], "set", a["key"], a["value"]],
    },
    "env_unset": {
        "write": True,
        "description": "Remove a key from a site's .env.",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"}, "key": {"type": "string"}},
            "required": ["domain", "key"]},
        "build": lambda a: ["env", a["domain"], "unset", a["key"]],
    },

    # ---- more site operations (write tier) -------------------------------
    "add_site": {
        "write": True, "timeout": 1800,
        "description": "Provision a new site non-interactively. Pass the same fields the "
                       "wizard asks for (domain, root, framework, repo, branch, php_version, tls, tls_email).",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"}, "root": {"type": "string"},
            "framework": {"type": "string"}, "repo": {"type": "string"},
            "branch": {"type": "string"}, "php_version": {"type": "string"},
            "tls": {"type": "boolean"}, "tls_email": {"type": "string"}},
            "required": ["domain", "root"]},
        "build": lambda a: _add_args(a),
    },
    "import_site": {
        "write": True,
        "description": "Adopt an already-deployed site without deploying it.",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"}, "root": {"type": "string"}},
            "required": ["domain", "root"]},
        "build": lambda a: ["import", a["domain"], a["root"]],
    },
    "diff": {
        "description": "Preview what a deploy would apply (commits + migrations).",
        "schema": {"type": "object", "properties": {"domain": {"type": "string"}}, "required": ["domain"]},
        "build": lambda a: ["diff", a["domain"]],
    },
    "release": {
        "write": True, "timeout": 1800,
        "description": "Atomic releases: init | deploy | list | rollback | prune.",
        "schema": {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["init", "deploy", "list", "rollback", "prune"]},
            "domain": {"type": "string"}},
            "required": ["action", "domain"]},
        "build": lambda a: ["release", a["action"], a["domain"]],
    },
    "php": {
        "write": True, "timeout": 600,
        "description": "Run an artisan/php command on a site (e.g. 'artisan migrate --force').",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"},
            "args": {"type": "array", "items": {"type": "string"}}},
            "required": ["domain", "args"]},
        "build": lambda a: ["php", a["domain"], *a.get("args", [])],
    },
    "db_export": {
        "write": True, "timeout": 600,
        "description": "Dump a site's database to a local .sql.gz (path optional).",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"}, "outfile": {"type": "string"}},
            "required": ["domain"]},
        "build": lambda a: ["db", "export", a["domain"]] + ([a["outfile"]] if a.get("outfile") else []),
    },
    "db_import": {
        "write": True, "timeout": 1800,
        "description": "Import a local .sql/.sql.gz dump into a site's database.",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"}, "file": {"type": "string"}},
            "required": ["domain", "file"]},
        "build": lambda a: ["db", "import", a["domain"], a["file"]],
    },
    "cron": {
        "write": True,
        "description": "Manage custom cron jobs: list | add (schedule+command) | remove (n).",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"},
            "action": {"type": "string", "enum": ["list", "add", "remove"]},
            "schedule": {"type": "string"}, "command": {"type": "string"}, "number": {"type": "integer"}},
            "required": ["domain", "action"]},
        "build": lambda a: _cron_args(a),
    },
    "audit_fix": {
        "write": True,
        "description": "Apply a single audit remediation by id (or 'all' for every auto-fixable finding).",
        "schema": {"type": "object", "properties": {
            "id": {"type": "string", "description": "Finding id, or 'all'."},
            "domain": {"type": "string"}},
            "required": ["id"]},
        "build": lambda a: (["audit", "fixall"] if a["id"] == "all" else ["audit", "fix", a["id"]])
                           + ([a["domain"]] if a.get("domain") else []),
    },
    "git": {
        "write": True, "timeout": 600,
        "description": "Git ops on a site's checkout: log|status|branches|pull|deploy|push|"
                       "branch|tag|pr|merge|deploy-key (and more). args after the action are passed through.",
        "schema": {"type": "object", "properties": {
            "action": {"type": "string"}, "domain": {"type": "string"},
            "args": {"type": "array", "items": {"type": "string"}}},
            "required": ["action", "domain"]},
        "build": lambda a: ["git", a["action"], a["domain"], *a.get("args", [])],
    },
    "upload": {
        "write": True, "timeout": 600,
        "description": "Copy a local file/dir to a site's server (remote path absolute or relative to app root).",
        "schema": {"type": "object", "properties": {
            "domain": {"type": "string"}, "local": {"type": "string"}, "remote": {"type": "string"}},
            "required": ["domain", "local", "remote"]},
        "build": lambda a: ["upload", a["domain"], a["local"], a["remote"]],
    },
    "config_get": {
        "description": "Read a global config value (or list all with no key).",
        "schema": {"type": "object", "properties": {"key": {"type": "string"}}},
        "build": lambda a: (["config", "get", a["key"]] if a.get("key") else ["config", "list"]),
    },
    "config_set": {
        "write": True,
        "description": "Set a global config value (git author/token, TLS email, defaults).",
        "schema": {"type": "object", "properties": {
            "key": {"type": "string"}, "value": {"type": "string"}},
            "required": ["key", "value"]},
        "build": lambda a: ["config", "set", a["key"], a["value"]],
    },
    "connect_server": {
        "write": True, "timeout": 300,
        "description": "Register a target server: name + user@host[:port].",
        "schema": {"type": "object", "properties": {
            "name": {"type": "string"}, "target": {"type": "string", "description": "user@host[:port]"}},
            "required": ["name", "target"]},
        "build": lambda a: ["connect", a["name"], a["target"]],
    },
    "use_server": {
        "write": True,
        "description": "Set the default target server.",
        "schema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
        "build": lambda a: ["use", a["name"]],
    },

    # ---- escape hatch: run any server subcommand -------------------------
    "run": {
        "write": True, "timeout": 1800,
        "description": "Run any `server` subcommand directly (full CLI access). "
                       "Pass the argument list, e.g. [\"update\",\"clicketta.net\"]. "
                       "See `help` for the command list.",
        "schema": {"type": "object", "properties": {
            "args": {"type": "array", "items": {"type": "string"}}},
            "required": ["args"]},
        "build": lambda a: list(a.get("args", [])),
    },
    "help": {
        "description": "Show the full list of server-manager commands and options.",
        "schema": {"type": "object", "properties": {}},
        "build": lambda a: ["help"],
    },
}


def _add_args(a):
    # Non-interactive add via the two-phase contract: write the answers JSON to
    # a local temp file and run `add --apply --answers <file>` (the file is read
    # on the control side, i.e. here).
    answers = {
        "domain": a["domain"],
        "path": a.get("root", ""),
        "framework": a.get("framework", "static"),
        "repo": a.get("repo", ""),
        "branch": a.get("branch", "main"),
        "php_version": a.get("php_version", "8.3"),
        "tls": bool(a.get("tls", True)),
        "tls_email": a.get("tls_email", ""),
    }
    if a.get("server"):
        answers["server"] = a["server"]
    fd, path = tempfile.mkstemp(prefix="sm-mcp-answers-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(answers, f)
    return ["add", "--apply", "--answers", path]


def _cron_args(a):
    action = a["action"]
    if action == "add":
        return ["cron", a["domain"], "add", a.get("schedule", ""), a.get("command", "")]
    if action == "remove":
        return ["cron", a["domain"], "remove", str(a.get("number", ""))]
    return ["cron", a["domain"], "list"]


def available_tools():
    out = {}
    for name, t in TOOLS.items():
        if t.get("write") and READONLY:
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
                    f"(In SM_MCP_READONLY mode mutating tools are hidden; "
                    f"reading .env secrets needs SM_MCP_ALLOW_SECRETS=1.)"}],
                "isError": True,
            })
            return
        spec = tools[name]
        try:
            cli_args = spec["build"](args)
        except KeyError as e:
            reply(req_id, {"content": [{"type": "text", "text": f"Missing argument: {e}"}], "isError": True})
            return
        # 'help' prints usage (not JSON); the interactive ui/mcp can't run here.
        if name == "help":
            res = run_help()
        elif name == "run" and cli_args and cli_args[0] in ("ui", "mcp"):
            res = {"ok": False, "error": f"'{cli_args[0]}' is interactive and can't run over MCP."}
        else:
            res = run_server(cli_args, timeout=spec.get("timeout", 120))
        reply(req_id, {
            "content": [{"type": "text", "text": result_text(res)}],
            "isError": not res.get("ok", False),
        })
    else:
        error(req_id, -32601, f"Method not found: {method}")


def main():
    log(f"ready (bin={SERVER_BIN}, writes={'OFF (readonly)' if READONLY else 'on (approve per call)'}, "
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
