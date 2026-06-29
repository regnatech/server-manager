# shellcheck shell=bash
#
# ui.sh — terminal UI primitives: colours, logging, spinner, prompts,
# progress bar and the final report box. Everything degrades gracefully
# when stdout is not a TTY (CI-safe).
#
# This file is meant to be sourced, never executed.

# ---------------------------------------------------------------------------
# Colour / capability detection
# ---------------------------------------------------------------------------

ui_init_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    UI_TTY=1
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
    C_GREY=$'\033[90m'
  else
    UI_TTY=0
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW=""
    C_BLUE="" C_MAGENTA="" C_CYAN="" C_GREY=""
  fi
}
ui_init_colors

# Glyphs (ASCII fallback when not a UTF-8 capable TTY)
if [[ "${UI_TTY}" == "1" && "${LANG:-}" == *UTF-8* ]]; then
  GLYPH_OK="✔" GLYPH_ERR="✖" GLYPH_WARN="⚠" GLYPH_INFO="•" GLYPH_ARROW="›"
else
  GLYPH_OK="[OK]" GLYPH_ERR="[!!]" GLYPH_WARN="[!]" GLYPH_INFO="-" GLYPH_ARROW=">"
fi

# ---------------------------------------------------------------------------
# Logging helpers (all to stderr so stdout stays clean for captured data)
# ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*" >&2; }
info() { printf '%s%s%s %s\n' "$C_BLUE" "$GLYPH_INFO" "$C_RESET" "$*" >&2; }
ok()   { printf '%s%s%s %s\n' "$C_GREEN" "$GLYPH_OK" "$C_RESET" "$*" >&2; }
warn() { printf '%s%s %s%s\n' "$C_YELLOW" "$GLYPH_WARN" "$*" "$C_RESET" >&2; }
err()  { printf '%s%s %s%s\n' "$C_RED" "$GLYPH_ERR" "$*" "$C_RESET" >&2; }

# Section header
section() {
  printf '\n%s%s%s %s%s\n' "$C_BOLD" "$C_CYAN" "$GLYPH_ARROW" "$*" "$C_RESET" >&2
}

# Banner shown at the top of interactive commands
banner() {
  printf '\n%s%s  server-manager%s  %s%s%s\n\n' \
    "$C_BOLD" "$C_MAGENTA" "$C_RESET" "$C_GREY" "${1:-}" "$C_RESET" >&2
}

# ---------------------------------------------------------------------------
# Spinner — run a command while animating, print OK/ERR with timing.
#   step "Message" cmd arg1 arg2 ...
# The command's stdout+stderr are captured; on failure they are shown.
# Returns the command's exit status.
# ---------------------------------------------------------------------------

step() {
  local msg="$1"; shift
  local logfile start end dur rc=0
  logfile="$(mktemp "${TMPDIR:-/tmp}/srvmgr-step.XXXXXX")"
  start="$(_ui_now)"

  if [[ "${UI_TTY}" == "1" ]]; then
    ( "$@" ) >"$logfile" 2>&1 &
    local pid=$!
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
      local f="${frames:i++%${#frames}:1}"
      printf '\r%s%s%s %s' "$C_CYAN" "$f" "$C_RESET" "$msg" >&2
      _ui_sleep 0.08
    done
    tput cnorm 2>/dev/null || true
    wait "$pid" || rc=$?
    printf '\r\033[K' >&2
  else
    say "  … ${msg}"
    ( "$@" ) >"$logfile" 2>&1 || rc=$?
  fi

  end="$(_ui_now)"
  dur="$(_ui_elapsed "$start" "$end")"

  if [[ $rc -eq 0 ]]; then
    printf '%s%s%s %s %s(%ss)%s\n' "$C_GREEN" "$GLYPH_OK" "$C_RESET" "$msg" "$C_GREY" "$dur" "$C_RESET" >&2
  else
    printf '%s%s%s %s\n' "$C_RED" "$GLYPH_ERR" "$C_RESET" "$msg" >&2
    if [[ -s "$logfile" ]]; then
      printf '%s' "$C_GREY" >&2
      sed 's/^/    │ /' "$logfile" >&2
      printf '%s' "$C_RESET" >&2
    fi
  fi
  rm -f "$logfile"
  return $rc
}

# step_capture "Message" cmd ... — like step(), but the command's STDOUT is
# forwarded to this function's stdout (so it can be captured with $(...)),
# while the spinner/result render on stderr. Use for "run with progress and
# keep the output". Returns the command's exit status.
step_capture() {
  local msg="$1"; shift
  local outfile errfile start end dur rc=0
  outfile="$(mktemp "${TMPDIR:-/tmp}/srvmgr-cap.XXXXXX")"
  errfile="$(mktemp "${TMPDIR:-/tmp}/srvmgr-cap.XXXXXX")"
  start="$(_ui_now)"

  if [[ "${UI_TTY}" == "1" ]]; then
    ( "$@" ) >"$outfile" 2>"$errfile" &
    local pid=$!
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r%s%s%s %s' "$C_CYAN" "${frames:i++%${#frames}:1}" "$C_RESET" "$msg" >&2
      _ui_sleep 0.08
    done
    tput cnorm 2>/dev/null || true
    wait "$pid" || rc=$?
    printf '\r\033[K' >&2
  else
    say "  … ${msg}"
    ( "$@" ) >"$outfile" 2>"$errfile" || rc=$?
  fi

  end="$(_ui_now)"; dur="$(_ui_elapsed "$start" "$end")"
  if [[ $rc -eq 0 ]]; then
    printf '%s%s%s %s %s(%ss)%s\n' "$C_GREEN" "$GLYPH_OK" "$C_RESET" "$msg" "$C_GREY" "$dur" "$C_RESET" >&2
  else
    printf '%s%s%s %s\n' "$C_RED" "$GLYPH_ERR" "$C_RESET" "$msg" >&2
    [[ -s "$errfile" ]] && { printf '%s' "$C_GREY" >&2; sed 's/^/    │ /' "$errfile" >&2; printf '%s' "$C_RESET" >&2; }
  fi
  cat "$outfile"
  rm -f "$outfile" "$errfile"
  return $rc
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

# ask "Prompt" "default" -> echoes the answer (or default) on stdout
ask() {
  local prompt="$1" default="${2:-}" reply
  local hint=""
  [[ -n "$default" ]] && hint=" ${C_GREY}[${default}]${C_RESET}"
  printf '%s%s%s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET" "$hint" "" >&2
  IFS= read -r reply || true
  printf '%s' "${reply:-$default}"
}

# ask_required "Prompt" "default" -> loops until non-empty
ask_required() {
  local prompt="$1" default="${2:-}" answer
  while :; do
    answer="$(ask "$prompt" "$default")"
    [[ -n "$answer" ]] && { printf '%s' "$answer"; return 0; }
    warn "A value is required."
  done
}

# prompt_secret "Prompt" -> reads without echo
prompt_secret() {
  local prompt="$1" reply
  printf '%s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET" >&2
  IFS= read -rs reply || true
  printf '\n' >&2
  printf '%s' "$reply"
}

# confirm "Question" "Y" -> returns 0 for yes, 1 for no. Default Y or n.
confirm() {
  local prompt="$1" default="${2:-Y}" reply hint
  if [[ "${SRVMGR_ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  case "$default" in
    Y|y) hint="(Y/n)";;
    *)   hint="(y/N)";;
  esac
  while :; do
    printf '%s%s%s %s ' "$C_BOLD" "$prompt" "$C_RESET" "$hint" >&2
    IFS= read -r reply || true
    reply="${reply:-$default}"
    case "$reply" in
      Y|y|yes|Yes|YES) return 0;;
      N|n|no|No|NO)    return 1;;
      *) warn "Please answer y or n.";;
    esac
  done
}

# present "Label" "value" "confirm?"
#   Shows a discovered value and, when confirm is non-empty, lets the user
#   accept it (Enter) or override it. Echoes the final value on stdout.
present() {
  local label="$1" value="$2" allow_override="${3:-1}"
  if [[ -n "$value" ]]; then
    if [[ "$allow_override" == "1" ]]; then
      printf '%s%s:%s %s%s%s ' "$C_BOLD" "$label" "$C_RESET" "$C_GREEN" "$value" "$C_RESET" >&2
      local reply
      printf '%s(Enter to confirm, or type new value)%s ' "$C_GREY" "$C_RESET" >&2
      IFS= read -r reply || true
      printf '%s' "${reply:-$value}"
    else
      printf '%s%s:%s %s%s%s\n' "$C_BOLD" "$label" "$C_RESET" "$C_GREEN" "$value" "$C_RESET" >&2
      printf '%s' "$value"
    fi
  else
    ask_required "$label"
  fi
}

# ---------------------------------------------------------------------------
# Progress bar for multi-item loops:  progress_bar current total "label"
# ---------------------------------------------------------------------------

progress_bar() {
  local cur="$1" total="$2" label="${3:-}"
  [[ "${UI_TTY}" != "1" ]] && return 0
  local width=30 filled
  (( total == 0 )) && total=1
  filled=$(( cur * width / total ))
  local bar=""
  local i
  for ((i=0;i<width;i++)); do
    if (( i < filled )); then bar+="█"; else bar+="░"; fi
  done
  printf '\r%s%s%s %3d%%  %s' "$C_CYAN" "$bar" "$C_RESET" $(( cur * 100 / total )) "$label" >&2
  (( cur >= total )) && printf '\n' >&2
}

# ---------------------------------------------------------------------------
# Final report box
#   report_box "Title" "line 1" "line 2" ...
# ---------------------------------------------------------------------------

report_box() {
  local title="$1"; shift
  # Collect non-empty lines (optional fields are passed as "${var:+...}").
  local lines=() line width=${#title}
  for line in "$@"; do
    [[ -z "$line" ]] && continue
    lines+=("$line")
    (( ${#line} > width )) && width=${#line}
  done
  width=$(( width + 2 ))
  local top="" i
  for ((i=0;i<width;i++)); do top+="─"; done
  printf '%s┌%s┐%s\n' "$C_GREEN" "$top" "$C_RESET" >&2
  printf '%s│ %s%-*s%s │%s\n' "$C_GREEN" "$C_BOLD" $(( width - 2 )) "$title" "$C_RESET$C_GREEN" "$C_RESET" >&2
  printf '%s├%s┤%s\n' "$C_GREEN" "$top" "$C_RESET" >&2
  if (( ${#lines[@]} > 0 )); then
    for line in "${lines[@]}"; do
      printf '%s│%s %-*s %s│%s\n' "$C_GREEN" "$C_RESET" $(( width - 2 )) "$line" "$C_GREEN" "$C_RESET" >&2
    done
  fi
  printf '%s└%s┘%s\n' "$C_GREEN" "$top" "$C_RESET" >&2
}

# ---------------------------------------------------------------------------
# Time helpers (used for spinner timing and deploy duration)
# ---------------------------------------------------------------------------

# Pick a high-resolution clock once. EPOCHREALTIME (bash 5) is cheapest; else
# GNU date (%N), then perl, then integer seconds (BSD date has no %N).
_ui_detect_timer() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    _UI_TIMER=epochrealtime
  elif [[ "$(date +%N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
    _UI_TIMER=gnudate
  elif command -v perl >/dev/null 2>&1; then
    _UI_TIMER=perl
  else
    _UI_TIMER=seconds
  fi
}
_ui_detect_timer

# _ui_now -> seconds with fractional part when available
_ui_now() {
  case "$_UI_TIMER" in
    epochrealtime) printf '%s' "${EPOCHREALTIME/,/.}";;
    gnudate)       date +%s.%N;;
    perl)          perl -MTime::HiRes -e 'printf "%.3f", Time::HiRes::time()';;
    *)             date +%s;;
  esac
}

# _ui_elapsed start end -> formatted seconds (1 decimal)
_ui_elapsed() {
  awk -v a="$1" -v b="$2" 'BEGIN { d=b-a; if (d<0) d=0; printf "%.1f", d }'
}

# _ui_sleep — fractional sleep that works even where `sleep 0.1` doesn't
_ui_sleep() {
  sleep "$1" 2>/dev/null || sleep 1
}
