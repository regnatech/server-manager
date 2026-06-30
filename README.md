# server-manager

**A zero-config CLI for deploying and managing web apps on remote Linux servers
over SSH.**

Point it at a server, run a wizard once, and you get intelligent zero‑downtime
deploys, rollbacks, TLS, databases, cron, workers and a security audit. There
are no agents to install on the server and no config files to hand‑edit —
server‑manager probes the box, discovers your project, and remembers everything
under `/etc/server-manager/` on the server itself.

Pure Bash over SSH: runs anywhere with `bash` + `ssh`.

---

## Table of contents

- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Command reference](#command-reference)
- [Examples](#examples)
- [Self‑healing deploys](#self-healing-deploys)
- [Security audit](#security-audit)
- [The JSON protocol](#the-json-protocol)
- [Where things live](#where-things-live)
- [Development](#development)
- [License](#license)

---

## Features

- **Wizard (`server add`)** — probes the server, auto‑detects the framework
  (Laravel, Symfony, Statamic, WordPress, static, Node/Next/Nuxt, reverse
  proxy), and asks only what it can't infer.
- **Intelligent deploy (`server update`)** — backup → maintenance mode →
  `git pull` (clones on first deploy) → Composer → frontend build → migrate →
  cache rebuild → restart → health check, with a timed report. Brings the site
  back online automatically if a step fails.
- **Self‑healing deploys** — diagnoses a failed build step and applies a
  **targeted** fix, then retries: a missing PHP extension installs exactly
  `php<ver>-<ext>`, a missing Composer/Node/package‑manager is provisioned, etc.
- **Security audit (`server audit`)** — analyses the server's posture and offers
  **one‑click fixes** for the issues it finds.
- **Rollback** — restores code, database, `.env`, dependencies and caches from
  the pre‑deploy snapshot.
- **Provisioning** — installs PHP‑FPM (+ common extensions, Composer), MariaDB,
  the Node toolchain, supervisor workers and the Laravel scheduler as needed.
- **TLS** — Let's Encrypt via certbot, on by default in the wizard.
- **Files & config** — push files/dirs (`server upload`) and edit the remote
  `.env` in place (`server env`) without leaving the CLI.

---

## How it works

```
┌──────────────────────┐        SSH         ┌────────────────────────┐       SSH
│  You (CLI: bash+ssh)  │  ───────────────▶  │  Control node (Linux)  │  ───────────▶  managed
│                       │                    │  server-manager engine │   per-server   servers
└──────────────────────┘                    │  (bash)                │ ◀───────────  (targets)
                                             └────────────────────────┘
```

The CLI runs the engine and SSHes out to each managed server. State lives on
each managed server under `/etc/server-manager/`; you never edit it by hand.
A single box can also manage **itself** (`server connect-self`).

---

## Requirements

**Control side (where you run `server`):** `bash` ≥ 3.2 and an OpenSSH client.
On Linux/macOS these are built in; on **Windows** use Git Bash or WSL (see
[Install](#install)). Password auth additionally needs `sshpass`.

**Managed server:** SSH access as root **or** a sudo user with passwordless
sudo (sudo can't prompt over a non‑interactive channel; `server connect` checks
this and tells you if it's missing). Debian/Ubuntu (apt) is the primary target;
RHEL‑family (dnf/yum) is supported on a best‑effort basis.

---

## Install

**Linux / macOS**

```bash
git clone https://github.com/regnatech/server-manager.git
cd server-manager
./install.sh                 # symlinks ./bin/server onto your PATH
# or: make install
server help
```

**Windows**

> ⚠️ **WSL is required** (the engine is Bash + OpenSSH). Install it once in an
> admin PowerShell, then reopen your terminal:
> ```powershell
> wsl --install
> ```
> Git Bash also works as an alternative.

A launcher (`bin\server.cmd` / `bin\server.ps1`) finds the Bash backend for you,
so `server …` works from `cmd` or PowerShell just like on Linux:

```powershell
git clone https://github.com/regnatech/server-manager.git
cd server-manager
./install.ps1                # adds bin\ to your PATH (finds Git Bash / WSL)
# open a new terminal:
server help
```

`.gitattributes` keeps the shell scripts LF on Windows checkouts. Password auth
additionally needs `sshpass` (available in WSL; in Git Bash prefer key auth).

## Quick start

```bash
# 1. Register a server (probes SSH + sudo). Add -p to use a password.
server connect prod deploy@203.0.113.10
server connect prod deploy@203.0.113.10:22 -i ~/.ssh/id_ed25519
#    …or manage the box you're on:
server connect-self

# 2. Add a site — the wizard discovers and provisions it.
server add clicketta.site /var/www/clicketta/public

# 3. Deploy (clones the repo on the first run).
server update clicketta.site

# 4. Something broke? Roll back the last deploy.
server rollback clicketta.site
```

### Command reference

| Command | Description |
|---|---|
| `server ui` | Full‑screen terminal control panel — manage everything interactively. |
| `server mcp` | Run the MCP server so AI assistants can drive the CLI ([docs](docs/mcp.md)). |
| `server connect <name> user@host[:port] [-i key] [-p]` | Register a server (probes SSH + sudo). |
| `server connect-self [name]` | Register the current machine as a managed target (self‑host). |
| `server use <name>` | Set the default server. |
| `server servers` | List registered servers. |
| `server add [domain] [root]` | Wizard: discover, configure, provision (nginx, DB, TLS). |
| `server update <site>` | Intelligent, near‑zero‑downtime deploy with health check. |
| `server rollback <site> [git-ref]` | Revert the last deploy (code + data) or to a ref. |
| `server release <init\|deploy\|list\|rollback\|prune> <site>` | Atomic, symlink‑switched releases. |
| `server ssl <site>` | Issue or renew the Let's Encrypt certificate. |
| `server list` | List managed sites, frameworks, TLS and last deploy. |
| `server import <domain> <root>` | Adopt an already‑deployed site (no deploy). |
| `server upload <site> <local> <remote>` | Copy a local file/dir to the site's server. |
| `server env <site> [show\|get\|set\|unset\|pull\|push\|edit]` | Manage the remote `.env`. |
| `server logs <site> [type]` | Tail remote logs (`nginx`\|`php`\|`laravel`\|`queue`). |
| `server php <site> [args…]` | Run artisan/php, or show/switch the PHP version. |
| `server db import\|export [site] [file]` | Import/export a site's database. |
| `server scheduler <site> [status\|on\|off]` | Laravel scheduler cron. |
| `server worker <site> [status\|setup\|restart\|logs\|remove]` | Background workers. |
| `server cron <site> [list\|add "<sched>" "<cmd>"\|remove <n>]` | Custom cron jobs. |
| `server git <action> <site> …` | Git ops, incl. `deploy-key` (set up an SSH deploy key). |
| `server audit [site]` | Security audit: findings + one‑click fixes. |
| `server audit fix <id> [site]` | Apply a single audit remediation. |
| `server metrics` · `server uptime [site\|--all]` | Health snapshot · HTTP health check. |
| `server config <list\|get\|set>` · `server notify …` | Global settings · notifications. |

**Global options:** `--server <name>` (target a specific server), `-y`/`--yes`
(non‑interactive), `--no-color`, `-h`/`--help`, `-V`/`--version`.

### Examples

```bash
# Target a non-default server for a one-off command
server update shop.example.com --server prod

# Tail Laravel logs
server logs clicketta.site laravel

# Run an artisan command on the remote
server php clicketta.site artisan migrate --force

# Database
server db export clicketta.site ./backup.sql.gz
server db import  clicketta.site ./seed.sql.gz

# Push a file and edit the remote .env
server upload clicketta.site ./service_account.json storage/service_account.json
server env    clicketta.site set APP_DEBUG false

# Private repo over SSH: provision a deploy key, then deploy
server git deploy-key clicketta.site      # prints a key to add on GitHub
server update clicketta.site

# Scheduler & workers
server scheduler clicketta.site on
server worker    clicketta.site setup

# Custom cron
server cron clicketta.site add "0 3 * * *" "php artisan backup:run"
server cron clicketta.site list
```

### Self‑healing deploys

When a build step fails because something is missing, the deploy **diagnoses the
error and applies a targeted fix**, then retries the step once instead of
aborting:

```
✖ Installing Composer dependencies      (laravel/framework requires ext-gd … missing)
• diagnosing the error…
✔ Auto-fix: installing PHP extension gd
✔ Installing Composer dependencies (retry)
```

Covered cases include: missing PHP extension (`ext-*` → installs exactly that
extension), missing `composer` / `unzip` / `git`, missing Node.js or the
project's package manager (npm/pnpm/yarn/bun), and Composer OOM (the limit is
disabled pre‑emptively). Disk‑full (`ENOSPC`) is reported rather than retried.

### Security audit

```bash
server audit                 # audit the default server
server audit prod-site.com   # include site-specific checks
server audit fix firewall    # apply one fix by id
```

Checks include: root SSH login, SSH password auth, firewall (ufw), fail2ban,
automatic security updates, pending security updates, world‑readable `.env`,
`.env` exposed over HTTP, and missing HTTPS. Each finding reports a severity and
a recommendation; the fixable ones can be remediated with a single command.

---

## The JSON protocol

`server --json <command>` makes the engine emit one JSON event per line (NDJSON)
instead of human output, so any tool can drive it and render live progress. The
contract is versioned and documented in
[`docs/json-protocol.md`](docs/json-protocol.md). In short:

```jsonc
{"t":"version","contract":"1","version":"0.1.0"}
{"t":"section","label":"Deploy"}
{"t":"step_start","id":"s2","label":"Pulling main from origin"}
{"t":"step_end","id":"s2","ok":true,"dur":1.4}
{"t":"data","kind":"audit","items":[ /* findings */ ]}
{"t":"report","title":"Deployed clicketta.site","fields":{ /* … */ }}
{"t":"done","ok":true}
```

The `add` wizard uses a two‑phase `--plan` / `--apply --answers <file>` flow so a
non‑interactive client can render the form, collect answers, and run it.

---

## Where things live

```
Control side (where you run `server`)             Managed server
~/.config/server-manager/                          /etc/server-manager/
  servers/<name>.conf   (connection records)         sites/<domain>.conf   (source of truth)
  sites.index           (domain → server)            deploys/             (history)
  config                (global prefs)             /var/backups/server-manager/  (snapshots)
```

SSH uses OpenSSH ControlMaster multiplexing, so a multi‑step deploy
authenticates once and runs fast.

---

## Development

```bash
make test     # run the unit test suite (pure bash, no dependencies)
make lint     # shellcheck (or bash -n) every script
make smoke    # Docker integration test (needs Docker)
```

The engine is layered: `lib/core/*` (ui, ssh, config, json), `lib/discovery/*`,
`lib/providers/*`, `lib/deploy/*` and `lib/commands/*`.

---

## License

MIT — see [LICENSE](LICENSE).
