# shellcheck shell=bash
#
# config.sh — persistence helpers.
#
# Two stores:
#   * Local control-machine registry under $SRVMGR_HOME (default
#     ~/.config/server-manager): server connection records, the global
#     prefs file, and the domain->server index.
#   * Remote site config lives on each managed server under
#     /etc/server-manager/ and is read/written through lib/core/ssh.sh.
#
# Config files are simple `key=value` text. Values are stored raw (no quoting)
# — one value per line, keys are [a-z0-9_]. This keeps them trivially
# greppable and human-readable, though the user should never need to edit them.

SRVMGR_HOME="${SRVMGR_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/server-manager}"
SRVMGR_SERVERS_DIR="$SRVMGR_HOME/servers"
SRVMGR_INDEX="$SRVMGR_HOME/sites.index"
SRVMGR_GLOBAL="$SRVMGR_HOME/config"

# Canonical remote locations (referenced by deploy/provision code too).
REMOTE_ETC="/etc/server-manager"
REMOTE_SITES="$REMOTE_ETC/sites"
REMOTE_BACKUPS="/var/backups/server-manager"

# Ensure the local config tree exists.
config_init_local() {
  mkdir -p "$SRVMGR_SERVERS_DIR"
  [[ -f "$SRVMGR_INDEX" ]] || : >"$SRVMGR_INDEX"
  [[ -f "$SRVMGR_GLOBAL" ]] || : >"$SRVMGR_GLOBAL"
}

# ---------------------------------------------------------------------------
# Generic key=value access against a local file
# ---------------------------------------------------------------------------

# kv_get <file> <key> -> value (empty if absent). Last occurrence wins.
kv_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  local line val=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$key="* ]] && val="${line#*=}"
  done <"$file"
  printf '%s' "$val"
}

# kv_set <file> <key> <value> — create/replace the key in place.
kv_set() {
  local file="$1" key="$2" value="$3"
  local dir; dir="$(dirname "$file")"
  mkdir -p "$dir"
  local tmp; tmp="$(mktemp "${dir}/.kv.XXXXXX")"
  local found=0 line
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "$key="* ]]; then
        printf '%s=%s\n' "$key" "$value" >>"$tmp"; found=1
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$file"
  fi
  (( found == 0 )) && printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Global prefs
# ---------------------------------------------------------------------------

global_get() { kv_get "$SRVMGR_GLOBAL" "$1"; }
global_set() { kv_set "$SRVMGR_GLOBAL" "$1" "$2"; }

# ---------------------------------------------------------------------------
# sites.index — maps a domain to the server that hosts it so that
# `server update <site>` can resolve the server without scanning all of them.
# Format: "<domain>\t<server>" per line.
# ---------------------------------------------------------------------------

# index_set <domain> <server>
index_set() {
  local domain="$1" server="$2"
  config_init_local
  local tmp; tmp="$(mktemp "${SRVMGR_HOME}/.idx.XXXXXX")"
  if [[ -f "$SRVMGR_INDEX" ]]; then
    awk -F'\t' -v d="$domain" '$1 != d' "$SRVMGR_INDEX" >"$tmp"
  fi
  printf '%s\t%s\n' "$domain" "$server" >>"$tmp"
  mv "$tmp" "$SRVMGR_INDEX"
}

# index_get_server <domain> -> server name (empty if unknown)
index_get_server() {
  local domain="$1"
  [[ -f "$SRVMGR_INDEX" ]] || return 0
  local line d s
  while IFS=$'\t' read -r d s || [[ -n "$d" ]]; do
    [[ "$d" == "$domain" ]] && { printf '%s' "$s"; return 0; }
  done <"$SRVMGR_INDEX"
}

# index_remove <domain>
index_remove() {
  local domain="$1"
  [[ -f "$SRVMGR_INDEX" ]] || return 0
  local tmp; tmp="$(mktemp "${SRVMGR_HOME}/.idx.XXXXXX")"
  local line d s
  while IFS=$'\t' read -r d s || [[ -n "$d" ]]; do
    [[ "$d" == "$domain" ]] && continue
    printf '%s\t%s\n' "$d" "$s" >>"$tmp"
  done <"$SRVMGR_INDEX"
  mv "$tmp" "$SRVMGR_INDEX"
}

# index_all -> prints "domain<TAB>server" lines (for `server list`)
index_all() {
  [[ -f "$SRVMGR_INDEX" ]] && cat "$SRVMGR_INDEX"
}

# ---------------------------------------------------------------------------
# Remote site config (source of truth).  These require a server to be selected
# via ssh_use_server first (they call ssh_exec / ssh_sudo from ssh.sh).
# ---------------------------------------------------------------------------

# remote_site_path <domain> -> the .conf path on the remote
remote_site_path() { printf '%s/%s.conf' "$REMOTE_SITES" "$1"; }

# remote_ensure_dirs — make sure /etc/server-manager exists on the remote.
remote_ensure_dirs() {
  ssh_sudo "mkdir -p $(shq "$REMOTE_SITES") $(shq "$REMOTE_BACKUPS") && chmod 755 $(shq "$REMOTE_ETC")"
}

# remote_site_exists <domain>
remote_site_exists() {
  ssh_exec "test -f $(shq "$(remote_site_path "$1")")"
}

# remote_site_get <domain> <key> -> value (exit 0 even if file/key absent)
remote_site_get() {
  local domain="$1" key="$2"
  ssh_exec "awk -F= -v k=$(shq "$key") '\$1==k{sub(/^[^=]*=/,\"\");v=\$0} END{print v}' $(shq "$(remote_site_path "$domain")") 2>/dev/null || true"
}

# remote_site_load <domain> — print the whole conf (key=value lines) to stdout.
remote_site_load() {
  ssh_exec "cat $(shq "$(remote_site_path "$1")") 2>/dev/null"
}

# site_load <domain> — fetch the remote site conf in one round-trip and parse
# it into SITE_* globals for the deploy/rollback commands.
site_load() {
  local domain="$1"
  SITE_DOMAIN="" SITE_ROOT="" SITE_APP_ROOT="" SITE_FRAMEWORK="" \
  SITE_PHP_VERSION="" SITE_PHP_SOCKET="" SITE_GIT_REMOTE="" SITE_GIT_BRANCH="" \
  SITE_NODE_PM="" SITE_HTTPS="" SITE_LE_EMAIL="" SITE_UPSTREAM="" \
  SITE_REDIS="" SITE_QUEUE="" SITE_HORIZON="" SITE_SCHEDULER="" SITE_OCTANE="" \
  SITE_WORKER_PROCS=""
  local raw; raw="$(remote_site_load "$domain")" || return 1
  [[ -n "$raw" ]] || return 1
  local line k v
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      domain)      SITE_DOMAIN="$v";;      root)        SITE_ROOT="$v";;
      app_root)    SITE_APP_ROOT="$v";;    framework)   SITE_FRAMEWORK="$v";;
      php_version) SITE_PHP_VERSION="$v";; php_socket)  SITE_PHP_SOCKET="$v";;
      git_remote)  SITE_GIT_REMOTE="$v";;  git_branch)  SITE_GIT_BRANCH="$v";;
      node_pm)     SITE_NODE_PM="$v";;     https)       SITE_HTTPS="$v";;
      le_email)    SITE_LE_EMAIL="$v";;    upstream)    SITE_UPSTREAM="$v";;
      redis)       SITE_REDIS="$v";;       queue)       SITE_QUEUE="$v";;
      horizon)     SITE_HORIZON="$v";;     scheduler)   SITE_SCHEDULER="$v";;
      octane)      SITE_OCTANE="$v";;      worker_procs) SITE_WORKER_PROCS="$v";;
    esac
  done <<<"$raw"
  [[ -n "$SITE_DOMAIN" ]]
}

# remote_site_set_kv <domain> <key> <value> — update a single key in the site
# conf, preserving every other line. Appends the key if it isn't present.
remote_site_set_kv() {
  local domain="$1" key="$2" value="$3"
  local raw; raw="$(remote_site_load "$domain")" || return 1
  [[ -n "$raw" ]] || return 1
  local out="" line found=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "${key}="* ]]; then
      out+="${key}=${value}"$'\n'; found=1
    else
      out+="${line}"$'\n'
    fi
  done <<<"$raw"
  (( found )) || out+="${key}=${value}"$'\n'
  printf '%s' "$out" | remote_site_write "$domain"
}

# remote_site_write <domain> < body — overwrite the site conf atomically
# (root-owned). Reads the full key=value body from stdin on the control side
# and embeds it into the remote script (the script itself is the remote's
# stdin, so the payload cannot also be streamed over stdin).
remote_site_write() {
  local domain="$1"
  local path; path="$(remote_site_path "$domain")"
  local body; body="$(cat)"
  ssh_script --sudo <<EOF
set -e
mkdir -p $(shq "$REMOTE_SITES")
cat > $(shq "$path").tmp <<'SRVMGR_PAYLOAD_EOF'
${body}
SRVMGR_PAYLOAD_EOF
chmod 0640 $(shq "$path").tmp
mv $(shq "$path").tmp $(shq "$path")
EOF
}
