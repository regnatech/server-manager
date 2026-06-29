# server-manager

**A zero-config control panel for deploying and managing web apps on remote
Linux servers over SSH — available as a CLI *and* a desktop app.**

Point it at a server, run a wizard once, and you get intelligent zero‑downtime
deploys, rollbacks, TLS, databases, cron, workers, a security audit, and a
built‑in terminal. There are no agents to install on the server and no config
files to hand‑edit — server‑manager probes the box, discovers your project, and
remembers everything under `/etc/server-manager/` on the server itself.

Two front‑ends, **one engine**:

| | |
|---|---|
| **CLI** (`server …`) | Pure Bash over SSH. Runs anywhere with `bash` + `ssh`. |
| **Desktop app** (Windows / macOS / Linux) | A Flutter UI that drives the same engine over SSH (pure‑Dart, no Bash on the client) and renders everything live. |

![dashboard](docs/screenshots/02-dashboard.png)

---

## Table of contents

- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Part A — The CLI](#part-a--the-cli)
  - [Install](#install)
  - [Quick start](#quick-start)
  - [Command reference](#command-reference)
  - [Examples](#examples)
  - [Self‑healing deploys](#self-healing-deploys)
  - [Security audit](#security-audit)
- [Part B — The desktop app](#part-b--the-desktop-app)
  - [What the app adds](#what-the-app-adds)
  - [Architecture](#architecture)
  - [Build & run](#build--run)
  - [Demo mode](#demo-mode)
  - [Screenshots](#screenshots)
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
  `git pull` → Composer → frontend build → migrate → cache rebuild → restart →
  health check, with a timed report. Brings the site back online automatically
  if a step fails.
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
- **Built‑in terminal** (app) — an interactive SSH shell, including a per‑site
  shell dropped straight into the app directory.

---

## How it works

```
┌──────────────────────┐        SSH         ┌────────────────────────┐       SSH
│  You                  │  ───────────────▶  │  Control node (Linux)  │  ───────────▶  managed
│  • CLI  (bash+ssh)    │   server --json    │  server-manager engine │   per-server   servers
│  • Desktop app (Dart) │ ◀───────────────   │  (bash)                │ ◀───────────  (targets)
└──────────────────────┘   NDJSON events     └────────────────────────┘
```

- The **CLI** runs the engine locally and SSHes out to each managed server.
- The **app** connects over SSH (pure‑Dart [`dartssh2`], native on Windows) to a
  Linux **control node** where the engine is installed, and drives it through a
  machine‑readable [JSON event protocol](#the-json-protocol). The control node
  SSHes to the managed servers exactly as the CLI does.

State lives on each managed server under `/etc/server-manager/`; you never edit
it by hand.

---

## Requirements

**Control side (CLI host or app control node):** `bash` ≥ 3.2 and an OpenSSH
client. On Linux/macOS these are built in; on **Windows** use Git Bash or WSL
(see [Install](#install)). Password auth additionally needs `sshpass`.

**Managed server:** SSH access as root **or** a sudo user with passwordless
sudo (sudo can't prompt over a non‑interactive channel; `server connect` checks
this and tells you if it's missing). Debian/Ubuntu (apt) is the primary target;
RHEL‑family (dnf/yum) is supported on a best‑effort basis.

**Desktop app (to build):** Flutter ≥ 3.27. Platform toolchains as usual
(Visual Studio for Windows, Xcode for macOS, GTK/clang/cmake/ninja for Linux).

---

## Part A — The CLI

### Install

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
The desktop app is fully native on Windows — see [Part B](#part-b--the-desktop-app).

### Quick start

```bash
# 1. Register a server (probes SSH + sudo). Add -p to use a password.
server connect prod deploy@203.0.113.10
server connect prod deploy@203.0.113.10:22 -i ~/.ssh/id_ed25519

# 2. Add a site — the wizard discovers and provisions it.
server add clicketta.site /var/www/clicketta/public

# 3. Deploy.
server update clicketta.site

# 4. Something broke? Roll back the last deploy.
server rollback clicketta.site
```

### Command reference

| Command | Description |
|---|---|
| `server connect <name> user@host[:port] [-i key] [-p]` | Register a server (probes SSH + sudo). |
| `server use <name>` | Set the default server. |
| `server servers` | List registered servers. |
| `server add [domain] [root]` | Wizard: discover, configure, provision (nginx, DB, TLS). |
| `server update <site>` | Intelligent, near‑zero‑downtime deploy with health check. |
| `server rollback <site> [git-ref]` | Revert the last deploy (code + data) or to a ref. |
| `server ssl <site>` | Issue or renew the Let's Encrypt certificate. |
| `server list` | List managed sites, frameworks, TLS and last deploy. |
| `server import <domain> <root>` | Adopt an already‑deployed site (no deploy). |
| `server logs <site> [type]` | Tail remote logs (`nginx`\|`php`\|`laravel`\|`queue`). |
| `server php <site> [args…]` | Run artisan/php, or show/switch the PHP version. |
| `server db import\|export [site] [file]` | Import/export a site's database. |
| `server scheduler <site> [status\|on\|off]` | Laravel scheduler cron. |
| `server worker <site> [status\|setup\|restart\|logs\|remove]` | Background workers. |
| `server cron <site> [list\|add "<sched>" "<cmd>"\|remove <n>]` | Custom cron jobs. |
| `server audit [site]` | Security audit: findings + one‑click fixes. |
| `server audit fix <id> [site]` | Apply a single audit remediation. |

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
a recommendation; the fixable ones can be remediated with a single command (or a
button in the app).

---

## Part B — The desktop app

A native desktop client (Windows‑first; also macOS, Linux, and a web build for
demos) that drives the same engine and renders everything live.

### What the app adds

- **Guided connect** — SSH key or password, with a "Test connection" check.
- **Dashboard** — an animated grid of site cards (health, framework, TLS, last
  deploy).
- **Live deploy timeline** — every step streams in real time with a spinner →
  check/cross, durations, and the self‑heal fail→fix→retry shown natively.
- **Per‑site workspace** — every tool for a site at the top (Overview, Deploy,
  Cron, Workers, Logs, SSL, Database, **Audit**) with a **shell already
  connected to that site's server** pinned below.
- **Security audit UI** — findings grouped by severity, each with a one‑click
  **Fix** button; the list shrinks as you fix things.
- **Interactive terminal** — a full xterm terminal over an SSH PTY.

### Architecture

The app is a thin, beautiful client. All logic stays in the Bash engine on the
control node; the app speaks the [JSON protocol](#the-json-protocol) over SSH:

```
Flutter (Riverpod • go_router • xterm)
   └── dartssh2 ──▶ control node ──▶ server --json <command>
                                     └── NDJSON events ──▶ live UI
```

### Build & run

The app lives in [`app/`](app/). It needs a Linux **control node** reachable
over SSH with server‑manager installed (see [Part A](#install)).

```bash
cd app
flutter pub get

# Windows
flutter build windows          # → build/windows/x64/runner/Release/
# (package as MSIX with the `msix` package if you want an installer)

# macOS
flutter build macos

# Linux
flutter build linux            # → build/linux/x64/release/bundle/

# Run during development
flutter run -d windows         # or -d macos / -d linux
```

> If you edit a model, regenerate JSON helpers with
> `dart run build_runner build --delete-conflicting-outputs`.

On first launch, enter your control node's SSH host/user and key (or password),
or click **Explore demo** to try the UI with canned data and no server.

### Demo mode

The app can run with no server at all — useful for trying it out, for the web
build, and for screenshots. It's driven by environment variables (native) or a
query param (web):

| Variable | Effect |
|---|---|
| `SM_DEMO=1` (or `?demo=1` on web) | Start connected to a canned in‑app backend. |
| `SM_ROUTE=/dashboard` | Open directly on a route. |
| `SM_TAB=audit` | Open a specific site tool (overview\|deploy\|cron\|workers\|logs\|ssl\|database\|audit). |
| `SM_AUTODEPLOY=1` | Auto‑start a demo deploy so the timeline animates. |

```bash
# Try the dashboard with demo data
SM_DEMO=1 SM_ROUTE=/dashboard ./server_manager_ui
```

### Screenshots

A gallery of all screens (captured from the native Linux build) lives in
[`docs/screenshots/`](docs/screenshots/). Highlights:

| Live deploy timeline | Security audit |
|---|---|
| ![deploy](docs/screenshots/03-deploy.png) | ![audit](docs/screenshots/08-audit.png) |

| Per‑site workspace + shell | Terminal |
|---|---|
| ![site](docs/screenshots/05-site.png) | ![terminal](docs/screenshots/07-terminal.png) |

---

## The JSON protocol

`server --json <command>` makes the engine emit one JSON event per line (NDJSON)
instead of human output, so any client can drive it and render live progress.
The contract is versioned and documented in
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
GUI can render the form, collect answers, and run non‑interactively.

---

## Where things live

```
Control side (CLI host / app control node)        Managed server
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
`lib/providers/*`, `lib/deploy/*` and `lib/commands/*`. The app's tests live in
`app/test/` (`flutter test`).

---

## License

MIT — see [LICENSE](LICENSE).
