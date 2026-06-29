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
  [[ -n "$_SSH_HOST" && -n "$_SSH_USER" ]] || die "Server record '${name}' is incomplete."
}

# Build the common ssh option array for the currently selected server.
_ssh_opts() {
  local sock="$SSH_CM_DIR/cm-srvmgr-%r@%h:%p"
  SSH_OPTS=(
    -o ControlMaster=auto
    -o "ControlPath=${sock}"
    -o ControlPersist=60s
    -o ConnectTimeout="${SRVMGR_SSH_TIMEOUT:-15}"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -p "$_SSH_PORT"
  )
  [[ -n "$_SSH_IDENTITY" ]] && SSH_OPTS+=(-i "$_SSH_IDENTITY")
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
  ssh "${SSH_OPTS[@]}" "${_SSH_USER}@${_SSH_HOST}" "bash -c $(shq "$cmd")"
}

# ssh_app_exec <dir> <command-string> — run an application command (composer,
# npm, artisan, git) as the login user inside <dir>, with a PATH that picks up
# the common per-user / local tool locations that non-login SSH shells miss.
ssh_app_exec() {
  local dir="$1" cmd="$2"
  ssh_exec "export PATH=\"\$HOME/.local/bin:\$HOME/bin:\$HOME/.composer/vendor/bin:\$HOME/.config/composer/vendor/bin:/usr/local/bin:/usr/bin:/bin:\$PATH\"; cd $(shq "$dir") && { $cmd ; }"
}

# ssh_sudo <command-string> — run with privilege escalation per server record.
ssh_sudo() {
  local cmd="$1"
  _ssh_opts
  mkdir -p "$SSH_CM_DIR"
  ssh "${SSH_OPTS[@]}" "${_SSH_USER}@${_SSH_HOST}" "$(become_wrap "$cmd")"
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
  ssh "${SSH_OPTS[@]}" "${_SSH_USER}@${_SSH_HOST}" "$runner"
}

# ssh_copy_to <local-path> <remote-path> — scp a file up (reuses the master).
ssh_copy_to() {
  local src="$1" dst="$2"
  _ssh_opts
  local scp_opts=(-o "ControlPath=$SSH_CM_DIR/cm-srvmgr-%r@%h:%p" -P "$_SSH_PORT")
  [[ -n "$_SSH_IDENTITY" ]] && scp_opts+=(-i "$_SSH_IDENTITY")
  scp "${scp_opts[@]}" "$src" "${_SSH_USER}@${_SSH_HOST}:${dst}"
}

# ssh_interactive <command-string>
#   Allocate a TTY and stream output live (for `logs -f`, `artisan tinker`,
#   etc.). Output is NOT captured — it goes straight to the user's terminal.
ssh_interactive() {
  local cmd="$1"
  _ssh_opts
  mkdir -p "$SSH_CM_DIR"
  ssh -t "${SSH_OPTS[@]}" "${_SSH_USER}@${_SSH_HOST}" "bash -lc $(shq "$cmd")"
}

# ssh_app_interactive <dir> <command-string> — interactive variant scoped to a
# directory with the augmented app PATH.
ssh_app_interactive() {
  local dir="$1" cmd="$2"
  ssh_interactive "export PATH=\"\$HOME/.local/bin:\$HOME/bin:/usr/local/bin:\$PATH\"; cd $(shq "$dir") && { $cmd ; }"
}

# ssh_close — drop the master connection for the selected server.
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
