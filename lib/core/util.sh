# shellcheck shell=bash
#
# util.sh — generic helpers: error handling, validation, small string utils.
# Sourced, never executed.

# Abort with a message and non-zero status.
die() {
  err "$*"
  exit 1
}

# require_cmd <cmd> [<cmd> ...] — fail if any local command is missing.
require_cmd() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    die "Missing required command(s): ${missing[*]}"
  fi
}

# Validate a domain name (RFC-ish, allows subdomains and single-label hosts).
is_valid_domain() {
  local d="$1"
  [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

# Validate a (loosely) plausible email.
is_valid_email() {
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

# Validate an absolute unix path.
is_abs_path() {
  [[ "$1" == /* ]]
}

# slugify <domain> — site short name from a domain (clicketta.site -> clicketta).
slugify() {
  local s="$1"
  s="${s%%.*}"                 # take label before first dot
  s="${s//[^a-zA-Z0-9_-]/-}"   # sanitise
  printf '%s' "$s"
}

# Trim leading/trailing whitespace.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Shell-quote a value for safe interpolation into a remote command string.
shq() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

# Confirm we are running under bash (the control-side code targets 3.2+ so it
# runs out of the box on stock macOS). Remote payloads run on Linux bash 4/5.
require_bash() {
  if [[ -z "${BASH_VERSINFO:-}" ]]; then
    die "server-manager must run under bash."
  fi
  if (( BASH_VERSINFO[0] < 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
    die "server-manager requires bash >= 3.2 (found ${BASH_VERSION})."
  fi
}

# read_lines <command...> populates the global array READ_LINES with the
# command's output, one element per non-empty line. A bash-3.2-safe stand-in
# for `mapfile`/`readarray`.
read_lines() {
  READ_LINES=()
  local _l
  while IFS= read -r _l || [[ -n "$_l" ]]; do
    [[ -n "$_l" ]] && READ_LINES+=("$_l")
  done < <("$@")
}

# A UTC timestamp suitable for directory names: 20260629-143501
timestamp() {
  date -u +%Y%m%d-%H%M%S
}
