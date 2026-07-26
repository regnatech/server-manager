# shellcheck shell=bash
#
# ssh.sh — remote execution against a registered server.
#
# Uses OpenSSH ControlMaster multiplexing: the first connection to a server
# opens a background master; subsequent commands reuse the same socket, so a
# 12-step deploy authenticates once and runs fast. The master persists for a
# short while after the last command (ControlPersist) and is torn down on exit.
#
# Privilege escalation: many operations write to /etc or restart services.
# The server's record stores become=sudo|none. `become_wrap` prefixes commands
# with non-interactive sudo when needed. Passwordless sudo (or a root login) is
# required because sudo cannot prompt over a non-interactive SSH channel; this
# is probed at `server connect` time and surfaced to the user.

SSH_CM_DIR="${SSH_CM_DIR:-$HOME/.ssh}"

# Globals populated by ssh_use_server for the duration of a command.
_SSH_HOST="" _SSH_USER="" _SSH_PORT="" _SSH_IDENTITY="" _SSH_BECOME="none" _SSH_NAME=""
# Authentication: key (default) or password (supplied through sshpass).
_SSH_AUTH="key" _SSH_PASSWORD=""
# The account that owns the deployed tree (see ssh_app_exec). Set per site by
# site_load; empty means "run app commands as the login user".
_SSH_APP_USER=""

# ssh_use_server <server-name> — load a server record into the _SSH_* globals.
ssh_use_server() {
  local name="$1"
  local file="$SRVMGR_SERVERS_DIR/${name}.conf"
  [[ -f "$file" ]] || die "Unknown server '${name}'. Run 'server connect ${name} user@host' first."
  _SSH_NAME="$name"
  _SSH_HOST="$(kv_get "$file" host)"
  _SSH_USER="$(kv_get "$file" user)"
  _SSH_PORT="$(kv_get "$file" port)"; _SSH_PORT="${_SSH_PORT:-22}"
  _SSH_IDENTITY="$(kv_get "$file" identity_file)"
  _SSH_BECOME="$(kv_get "$file" become)"; _SSH_BECOME="${_SSH_BECOME:-none}"
  _SSH_AUTH="$(kv_get "$file" auth)"; _SSH_AUTH="${_SSH_AUTH:-key}"
  _SSH_PASSWORD="$(kv_get "$file" password)"
  # Per-site, not per-server: cleared here so one site's owner never leaks into
  # the next site's commands.
  _SSH_APP_USER=""
  [[ -n "$_SSH_HOST" && -n "$_SSH_USER" ]] || die "Server record '${name}' is incomplete."
}

# Build the common ssh option array AND the launcher (plain ssh, or sshpass for
# password auth) for the currently selected server. With ControlMaster the
# password is only actually used to open the master connection; multiplexed
# commands reuse the socket and never re-prompt.
_ssh_opts() {
  local sock="$SSH_CM_DIR/cm-srvmgr-%r@%h:%p"
  SSH_OPTS=(
    -o ControlMaster=auto
    -o "ControlPath=${sock}"
    -o ControlPersist=120s
    -o ConnectTimeout="${SRVMGR_SSH_TIMEOUT:-15}"
    -o StrictHostKeyChecking=accept-new
    -p "$_SSH_PORT"
  )
  SSH_LAUNCHER=(ssh)
  SCP_LAUNCHER=(scp)
  if [[ "$_SSH_AUTH" == "password" ]]; then
    command -v sshpass >/dev/null 2>&1 \
      || die "Server '${_SSH_NAME}' uses password auth but 'sshpass' is not installed (try: apt install sshpass)."
    export SSHPASS="$_SSH_PASSWORD"
    SSH_LAUNCHER=(sshpass -e ssh)
    SCP_LAUNCHER=(sshpass -e scp)
    # Force password (don't fall back to a wrong key) but allow keyboard-interactive.
    SSH_OPTS+=(-o BatchMode=no -o PubkeyAuthentication=no -o "PreferredAuthentications=password,keyboard-interactive")
  else
    # Key auth: never block on a password prompt.
    SSH_OPTS+=(-o BatchMode=yes)
    [[ -n "$_SSH_IDENTITY" ]] && SSH_OPTS+=(-i "$_SSH_IDENTITY")
  fi
  return 0   # never let a false [[ ]] above propagate under set -e
}

# become_wrap <command-string> — wrap in sudo if the server needs it.
become_wrap() {
  if [[ "$_SSH_BECOME" == "sudo" ]]; then
    printf 'sudo -n -- bash -c %s' "$(shq "$1")"
  else
    printf 'bash -c %s' "$(shq "$1")"
  fi
}

# ssh_exec <command-string>
#   Run a command on the selected server as the login user. The command runs
#   under `bash -c` so pipelines/&& behave predictably. stdout is forwarded.
ssh_exec() {
  local cmd="$1"
  _ssh_opts
  mkdir -p "$SSH_CM_DIR"
  "${SSH_LAUNCHER[@]}" "${SSH_OPTS[@]}" "${_SSH_USER}@${_SSH_HOST}" "bash -c $(shq "$cmd")"
}

# ssh_set_app_user <user> — declare which account owns the current site's tree.
# Called by site_load; cleared between sites so one site's owner never leaks
# into another's commands.
ssh_set_app_user() {
  _SSH_APP_USER="${1:-}"
  [[ "$_SSH_APP_USER" == "$_SSH_USER" ]] && _SSH_APP_USER=""
  return 0
}

# ssh_app_user_active — echo the account app commands will actually run as.
ssh_app_user_active() {
  if [[ -n "$_SSH_APP_USER" ]] && _ssh_can_become_app_user; then
    printf '%s' "$_SSH_APP_USER"
  else
    printf '%s' "$_SSH_USER"
  fi
}

# Whether we may switch to the app user: root can always; anyone else needs
# passwordless sudo, which is what the server record's become=sudo asserts.
_ssh_can_become_app_user() {
  [[ -n "$_SSH_APP_USER" ]] || return 1
  [[ "$_SSH_USER" == "root" || "$_SSH_BECOME" == "sudo" ]]
}

# _ssh_app_prelude <dir> — the environment every app command needs.
#
# HOME matters more than it looks: a web user's home is typically /var/www and
# not writable by that user, so composer, npm and artisan would fail trying to
# write caches into it. We point HOME at a per-user directory under /var/tmp —
# outside the deploy tree, so it survives releases and never lands in git.
_ssh_app_prelude() {
  local dir="$1" home_dir
  home_dir="/var/tmp/server-manager/home-\$(id -un)"
  printf 'export HOME=%s; mkdir -p "$HOME" 2>/dev/null || true; ' "\"$home_dir\""
  printf 'export COMPOSER_HOME="$HOME/.composer" NPM_CONFIG_CACHE="$HOME/.npm" XDG_CONFIG_HOME="$HOME/.config"; '
  printf 'export PATH="$HOME/.local/bin:$HOME/bin:$COMPOSER_HOME/vendor/bin:/usr/local/bin:/usr/bin:/bin:$PATH"; '
  # safe.directory keeps git happy when the tree is owned by someone else —
  # still needed for the fallback path where we could not switch user.
  printf 'export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=%s; ' "$(shq "$dir")"
}

# ssh_app_exec <dir> <command-string> — run an application command (composer,
# npm, artisan, git) inside <dir>.
#
# Runs as the account that OWNS the tree, not as the SSH login user. Deployed
# code is normally owned by the web user, and a login user that merely has sudo
# cannot write to it: `git fetch` fails on .git, composer cannot touch vendor,
# artisan cannot write its caches. Switching user is what makes an unattended
# deploy possible at all on such a host.
#
# Without a way to switch (no sudo, no root) it falls back to the login user, so
# hosts where the login user owns the tree behave exactly as before.
ssh_app_exec() {
  local dir="$1" cmd="$2"
  local prelude; prelude="$(_ssh_app_prelude "$dir")"

  # Terminate the group with a newline (not " ; }"): a multi-line $cmd ending in
  # a newline would otherwise produce "<newline> ; }" — a syntax error.
  local body="${prelude}cd $(shq "$dir") && { $cmd
}"

  if _ssh_can_become_app_user; then
    ssh_exec "$(_ssh_as_app_user "$body")"
  else
    ssh_exec "$body"
  fi
}

# _ssh_as_app_user <script> — wrap a script so it runs as the app user.
# `sudo -u <user> bash -c` bypasses the account's login shell, which for a web
# user is usually nologin. -H is deliberately NOT used: the prelude sets a HOME
# we know is writable, whereas the account's real home usually is not.
_ssh_as_app_user() {
  printf 'sudo -n -u %s bash -c %s' "$(shq "$_SSH_APP_USER")" "$(shq "$1")"
}

# ssh_app_script < heredoc — like ssh_script, but the payload runs as the app
# user. For writes into the deploy tree (rewriting a .env, dropping a file) so
# the result keeps the ownership the web server expects, instead of arriving
# owned by the login user or by root.
ssh_app_script() {
  _ssh_opts
  mkdir -p "$SSH_CM_DIR"
  local runner="bash -s"
  _ssh_can_become_app_user && runner="sudo -n -u $_SSH_APP_USER bash -s"
  "${SSH_LAUNCHER[@]}" "${SSH_OPTS[@]}" "${_SSH_USER}@${_SSH_HOST}" "$runner"
}

# ssh_app_read <path> — read a file the app user owns (a .env is 640, so the
# login user cannot see it). Falls back to sudo, then to a plain read.
ssh_app_read() {
  local path="$1"
  if _ssh_can_become_app_user; then
    ssh_exec "sudo -n -u $(shq "$_SSH_APP_USER") cat $(shq "$path") 2>/dev/null" && return 0
  fi
  if [[ "$_SSH_BECOME" == "sudo" || "$_SSH_USER" == "root" ]]; then
    ssh_sudo "cat $(shq "$path") 2>/dev/null" && return 0
  fi
  ssh_exec "cat $(shq "$path") 2>/dev/null"
}

# ssh_sudo <command-string> — run with privilege escalation per server record.
ssh_sudo() {
  local cmd="$1"
  _ssh_opts
  mkdir -p "$SSH_CM_DIR"
  "${SSH_LAUNCHER[@]}" "${SSH_OPTS[@]}" "${_SSH_USER}@${_SSH_HOST}" "$(become_wrap "$cmd")"
}

# ssh_script [--sudo] < heredoc
#   Pipe a multi-line bash payload to the remote and execute it with `bash -s`.
#   Used for discovery and for atomic multi-line remote steps. Reads the script
#   body from stdin.
ssh_script() {
  local sudo=0
  [[ "${1:-}" == "--sudo" ]] && { sudo=1; shift; }
  _ssh_opts
  mkdir -p "$SSH_CM_DIR"
  local runner="bash -s"
  [[ $sudo -eq 1 && "$_SSH_BECOME" == "sudo" ]] && runner="sudo -n bash -s"
  "${SSH_LAUNCHER[@]}" "${SSH_OPTS[@]}" "${_SSH_USER}@${_SSH_HOST}" "$runner"
}

# ssh_copy_to <local-path> <remote-path> [--recursive] — scp a file (or, with
# --recursive, a directory) up, reusing the master.
ssh_copy_to() {
  local src="$1" dst="$2" recursive="${3:-}"
  _ssh_opts
  local scp_opts=(-o "ControlPath=$SSH_CM_DIR/cm-srvmgr-%r@%h:%p" -P "$_SSH_PORT")
  [[ "$recursive" == "--recursive" ]] && scp_opts+=(-r)
  [[ "$_SSH_AUTH" != "password" && -n "$_SSH_IDENTITY" ]] && scp_opts+=(-i "$_SSH_IDENTITY")
  "${SCP_LAUNCHER[@]}" "${scp_opts[@]}" "$src" "${_SSH_USER}@${_SSH_HOST}:${dst}"
}

# ssh_interactive <command-string>
#   Allocate a TTY and stream output live (for `logs -f`, `artisan tinker`,
#   etc.). Output is NOT captured — it goes straight to the user's terminal.
ssh_interactive() {
  local cmd="$1"
  _ssh_opts
  mkdir -p "$SSH_CM_DIR"
  "${SSH_LAUNCHER[@]}" -t "${SSH_OPTS[@]}" "${_SSH_USER}@${_SSH_HOST}" "bash -lc $(shq "$cmd")"
}

# ssh_app_interactive <dir> <command-string> — interactive variant scoped to a
# directory with the augmented app PATH.
ssh_app_interactive() {
  local dir="$1" cmd="$2"
  ssh_interactive "export PATH=\"\$HOME/.local/bin:\$HOME/bin:/usr/local/bin:\$PATH\"; cd $(shq "$dir") && { $cmd
}"
}

# ssh_close — drop the master connection for the selected server. This only
# talks to the local control socket, so it needs no authentication.
ssh_close() {
  [[ -n "$_SSH_HOST" ]] || return 0
  _ssh_opts
  ssh "${SSH_OPTS[@]}" -O exit "${_SSH_USER}@${_SSH_HOST}" 2>/dev/null || true
}

# ssh_probe — verify connectivity (and report the remote user). Echoes the
# remote `id -un` on success; returns non-zero on failure.
ssh_probe() {
  ssh_exec 'id -un' 2>/dev/null
}

# ssh_probe_sudo — return 0 if passwordless sudo works (or login is root).
ssh_probe_sudo() {
  local who; who="$(ssh_exec 'id -un' 2>/dev/null)" || return 2
  [[ "$who" == "root" ]] && return 0
  ssh_exec 'sudo -n true' >/dev/null 2>&1
}

# remote_exists <path> — test for a remote file/dir. Returns 0 if present.
remote_exists() {
  ssh_exec "test -e $(shq "$1")"
}
