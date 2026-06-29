# server-manager

A **zero-config control panel for your servers**, driven entirely from the
command line. You answer a few questions once; server-manager discovers your
project, provisions it, and remembers everything. You never hand-edit a config
file.

```
server connect prod deploy@1.2.3.4   # register a server (once)
server add clicketta.site /var/www/clicketta/public
server update clicketta.site
server rollback clicketta.site
```

It runs on **your machine** and manages **remote Linux servers over SSH** — so
one install can drive many servers. State of record lives on each server under
`/etc/server-manager/`; your machine keeps only a small server registry under
`~/.config/server-manager/`.

---

## Features

- **Wizard (`server add`)** — asks only what it can't detect, confirms the rest.
- **Auto-discovery** — Laravel, Symfony, WordPress, Statamic, static sites,
  Node.js, React, Vue, Nuxt, Next.js, and reverse-proxy apps; plus git
  remote/branch/commit, PHP version + FPM socket, the JS package manager (from
  the lockfile), and Laravel specifics (Redis, queue, Horizon, scheduler,
  Octane).
- **MariaDB provisioning** — for Laravel/Statamic it installs MariaDB if
  missing, generates credentials, and writes them into `.env` (or prompts you
  to paste an `.env` when the project has none). Can also seed the database
  from a SQL dump during the wizard.
- **PHP-FPM provisioning** — installs the detected PHP version + common Laravel
  extensions (and Composer) when it isn't already on the server.
- **Scheduler & workers** — sets up the Laravel scheduler as a `/etc/cron.d`
  entry and background workers (`queue:work` or **Horizon**) under supervisor,
  automatically, and re-applies them on every deploy.
- **Database import/export** — `server db import`/`export` load a `.sql`/`.sql.gz`
  into a site's database or dump it out; credentials come from the site's `.env`.
- **Intelligent deploy (`server update`)** — backup → maintenance mode →
  `git pull` → Composer → frontend build → migrate → cache rebuild → restart
  services → health check, with a timed report. Brings the site back online
  automatically if a step fails.
- **Rollback (`server rollback`)** — restores code, database, `.env`,
  dependencies, caches and services from the pre-deploy snapshot.
- **TLS** — Let's Encrypt via certbot, on by default in the wizard.
- **Modern CLI UX** — colours, spinners, a final report box; degrades cleanly
  in non-TTY / CI environments.

## Requirements

**Control machine (where you run `server`):** bash ≥ 3.2 (stock macOS works),
OpenSSH, `curl`. That's it.

**Managed server:** Linux with SSH access. server-manager runs
**non-interactively**, so it needs either a **root** login or a user with
**passwordless (NOPASSWD) sudo** — it cannot type a sudo password over SSH.
`server connect` probes this and tells you if it's missing. Provisioning expects
`nginx` (and, for PHP apps, `php-fpm`; `certbot` for TLS) to be installable on
the host.

### Authentication: keys or password

`server connect` tries key-based login first. If that doesn't work it offers to:

1. **Set up key login now** (recommended) — copies your public key to the
   server after you type the password once; everything afterwards is key-based.
2. **Use the password every time** — stores the password locally (`chmod 600`)
   and authenticates each command through `sshpass` (`apt install sshpass`).

Force password mode directly with `-p`:

```bash
server connect main root@157.173.97.190 -p     # prompts for the password
```

Thanks to SSH connection multiplexing, the password is only used to open the
first connection of each command; the rest reuse it.

## Install

```bash
git clone https://github.com/<your-org>/server-manager.git
cd server-manager
./install.sh           # symlinks bin/server onto your PATH
server help
```

## Quickstart

```bash
# 1. Register a server (first one becomes the default).
server connect prod deploy@203.0.113.10
#    or with a key / port:
server connect prod deploy@203.0.113.10:22 -i ~/.ssh/id_ed25519

# 2. Add a site — the wizard discovers and provisions it.
server add clicketta.site /var/www/clicketta/public

# 3. Deploy.
server update clicketta.site

# 4. Something broke? Roll back the last deploy.
server rollback clicketta.site
```

## Commands

| Command | What it does |
|---|---|
| `server add [domain] [root]` | Wizard: discover, configure, provision (nginx, DB, TLS). |
| `server update <site>` | Intelligent, near-zero-downtime deploy with health check. |
| `server rollback <site> [git-ref]` | Revert the last deploy (code + data) or to a ref. |
| `server ssl <site>` | Issue / renew the Let's Encrypt certificate. |
| `server list` | List managed sites, frameworks, TLS and last deploy. |
| `server import <domain> <root>` | Adopt an already-deployed site (no deploy). |
| `server logs <site> [nginx\|php\|laravel\|queue] [-n N] [-f]` | Tail remote logs. |
| `server php <site> [set <ver> \| <args…>]` | Show/switch PHP, or run artisan/php. |
| `server db import [site] [file]` | Load a `.sql`/`.sql.gz` into a site's database (picks the site if omitted). |
| `server db export [site] [file]` | Dump a site's database to a local `.sql.gz`. |
| `server connect <name> user@host[:port] [-i key]` | Register a server. |
| `server use <name>` | Set the default server. |
| `server servers` | List registered servers. |

**Global options:** `--server <name>` (target a specific server), `-y/--yes`
(assume yes — non-interactive), `--no-color`, `-h/--help`, `-V/--version`.

The target server is the default unless `--server` is given; for site commands
it is inferred from where the site is registered, so `server update clicketta.site`
"just works".

## How it works

```
your machine                       managed server
────────────                       ──────────────
bin/server  ──ssh (ControlMaster)──▶ /etc/server-manager/sites/<domain>.conf   (source of truth)
~/.config/server-manager/            /etc/server-manager/sites/<domain>/deploys/ (history)
  servers/<name>.conf                /var/backups/server-manager/<domain>/<ts>/  (backups)
  sites.index  (domain → server)
```

A single SSH ControlMaster connection is reused for all the steps of a command,
so a multi-step deploy authenticates once and runs fast.

## The deploy flow (`server update`)

1. Verify the git repo & a clean working tree.
2. Back up `.env`, the nginx vhost and the database.
3. Enable maintenance mode (Laravel).
4. `git pull --ff-only`.
5. `composer install --no-dev --optimize-autoloader` (if `composer.json`).
6. Frontend build with the detected package manager (if `package.json`).
7. `migrate --force` and rebuild caches (Laravel).
8. Restart PHP-FPM, supervisor, queue workers, Horizon.
9. Disable maintenance mode.
10. Health check (nginx, php-fpm, supervisor, redis, HTTP 200) → timed report.

If any step fails, the site is brought back online and the attempt is recorded
as a failed deploy; `server rollback` can restore the previous state.

## Development

```bash
make test     # unit suite (no server needed; runs on bash 3.2)
make lint     # shellcheck if installed, else bash -n
make smoke    # full end-to-end test against a throwaway Docker "server"
```

The code is modular: `bin/server` dispatches to `lib/commands/*`, which build on
`lib/core/*` (ui, ssh, config), `lib/discovery/*`, `lib/deploy/*` and
`lib/providers/*`. Adding a framework = a detection branch in
`lib/discovery/framework.sh` + an nginx template.

## License

MIT — see [LICENSE](LICENSE).
