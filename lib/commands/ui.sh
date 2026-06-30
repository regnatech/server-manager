# shellcheck shell=bash
#
# ui.sh — `server ui` : a full-screen terminal control panel.
#
# A keyboard-driven TUI that lists your servers and sites and lets you run the
# usual operations (deploy, logs, rollback, TLS, audit, .env, shell) without
# remembering each command. Pure bash + ANSI: no ncurses, no dependencies.
#
# Implementation notes:
#   * Uses the alternate screen buffer (so the scrollback is left intact) and
#     hides the cursor; both are restored on exit via a trap.
#   * Raw input via `stty -icanon`; arrow keys are decoded from their escape
#     sequences. A bare ESC is detected with a short `min 0 time 1` poll so we
#     don't need bash-4 fractional `read -t` (control side may be bash 3.2).
#   * Each frame is composed into one buffer and painted from the home position
#     with per-line erase (\e[K) to avoid flicker.
#   * Running an action drops out of the alt screen, runs the real command with
#     a normal terminal, waits for a keypress, then restores the UI.

# Per-site action menu (label order maps to _ui_menu_action).
UI_MENU_LABELS=(
  "Deploy (update)"
  "View logs"
  "Roll back"
  "Renew TLS certificate"
  "Security audit"
  "Show .env"
  "Scale workers"
  "Toggle scheduler"
  "Open a shell"
  "Back"
)

# --- terminal -------------------------------------------------------------

_ui_enter_screen() {
  UI_STTY="$(stty -g 2>/dev/null)"
  stty -echo -icanon min 1 time 0 2>/dev/null
  printf '\033[?1049h\033[?25l\033[2J\033[H'
}

_ui_leave_screen() {
  printf '\033[?25h\033[?1049l'
  [[ -n "${UI_STTY:-}" ]] && stty "$UI_STTY" 2>/dev/null
}

_ui_size() {
  local s; s="$(stty size 2>/dev/null)"
  UI_ROWS="${s%% *}"; UI_COLS="${s##* }"
  [[ "$UI_ROWS" =~ ^[0-9]+$ ]] || UI_ROWS=24
  [[ "$UI_COLS" =~ ^[0-9]+$ ]] || UI_COLS=80
}

# Read one logical key; echoes a name: up|down|left|right|enter|back|quit|
# refresh|help|char:<c>.
_ui_read_key() {
  local c rest
  IFS= read -rsn1 c || { echo quit; return; }
  if [[ "$c" == $'\033' ]]; then
    stty min 0 time 1 2>/dev/null      # ~0.1s poll for the rest of the sequence
    IFS= read -rsn2 rest
    stty min 1 time 0 2>/dev/null
    case "$rest" in
      '[A'|'OA') echo up;;   '[B'|'OB') echo down;;
      '[C'|'OC') echo right;; '[D'|'OD') echo left;;
      '') echo back;;        *) echo other;;
    esac
    return
  fi
  case "$c" in
    ''|$'\n'|$'\r') echo enter;;   # '' = Enter: icrnl maps CR→NL, read eats the delimiter
    k|K) echo up;;   j|J) echo down;;
    h|H) echo left;; l|L) echo right;;
    q|Q) echo quit;; r|R) echo refresh;; '?') echo help;;
    $'\177'|$'\b') echo back;;
    *) printf 'char:%s' "$c";;
  esac
}

# --- rendering ------------------------------------------------------------

# _ui_pad <text> <width> — truncate or space-pad <text> to exactly <width>.
_ui_pad() {
  local s="$1" w="$2" len=${#1}
  if (( len > w )); then printf '%s' "${s:0:w}"
  else printf '%s%*s' "$s" $(( w - len )) ""; fi
}

_ui_row()     { UI_BUF+="$1"$'\033[K\n'; }
# Full-width reverse-video row from PLAIN text (so width math stays correct).
_ui_sel_row() { UI_BUF+=$'\033[7m'"$(_ui_pad "$1" "$UI_COLS")"$'\033[27m'$'\033[K\n'; }

_ui_render() {
  _ui_size
  UI_BUF=$'\033[H'
  if [[ "$UI_VIEW" == menu ]]; then _ui_render_menu; else _ui_render_sites; fi
  UI_BUF+=$'\033[J'
  printf '%s' "$UI_BUF"
}

# _ui_site_line <i> — echo a plain, fixed-width columns line for site <i>.
_ui_site_line() {
  local i="$1" row d s st fw tls last
  row="${UI_SITES[$i]}"; d="${row%%$'\t'*}"; s="${row#*$'\t'}"
  if [[ -n "${UI_STATUS[$i]:-}" ]]; then
    st="${UI_STATUS[$i]}"
    fw="${st%%$'\t'*}"; st="${st#*$'\t'}"
    tls="${st%%$'\t'*}"; last="${st#*$'\t'}"
  else
    fw="..."; tls="..."; last="..."
  fi
  printf '%-24.24s %-11.11s %-4.4s %-22.22s %s' "$d" "$fw" "$tls" "$last" "$s"
}

_ui_render_sites() {
  local def scount
  def="$(registry_default)"
  scount="$(registry_list_names | grep -c . 2>/dev/null || echo 0)"
  _ui_row "${C_BOLD}${C_MAGENTA} server-manager ${C_RESET}${C_GREY}— terminal control panel${C_RESET}"
  _ui_row ""
  _ui_row "${C_GREY}Servers:${C_RESET} ${scount}    ${C_GREY}default:${C_RESET} ${def:-—}"
  _ui_row ""
  _ui_row "${C_BOLD}SITES${C_RESET} ${C_GREY}(${#UI_SITES[@]})${C_RESET}"
  if (( ${#UI_SITES[@]} == 0 )); then
    _ui_row ""
    _ui_row "  ${C_GREY}No sites yet — press 'a' to add one.${C_RESET}"
  else
    local hdr; hdr="  $(printf '%-24.24s %-11.11s %-4.4s %-22.22s %s' \
      DOMAIN FRAMEWORK TLS 'LAST DEPLOY' SERVER)"
    _ui_row "${C_GREY}${hdr:0:UI_COLS}${C_RESET}"
    local i ln
    for i in "${!UI_SITES[@]}"; do
      if (( i == UI_SEL )); then
        _ui_sel_row "> $(_ui_site_line "$i")"
      else
        ln="  $(_ui_site_line "$i")"; _ui_row "${ln:0:UI_COLS}"
      fi
    done
  fi
  _ui_row ""
  [[ -n "${UI_MSG:-}" ]] && _ui_row "${C_YELLOW}${UI_MSG}${C_RESET}"
  _ui_row "${C_GREY}↑/↓ move · enter open · a add · r refresh · ? help · q quit${C_RESET}"
}

_ui_render_menu() {
  _ui_row "${C_BOLD}${C_CYAN} ${UI_DOMAIN} ${C_RESET}${C_GREY}on ${UI_SERVER}${C_RESET}"
  _ui_row ""
  _ui_row "  ${C_GREY}Framework${C_RESET}  $(printf '%-16s' "${UI_DET_FW:-…}")${C_GREY}TLS${C_RESET}  ${UI_DET_TLS:-…}"
  _ui_row "  ${C_GREY}Scheduler${C_RESET}  $(printf '%-16s' "${UI_DET_SCHED:-…}")${C_GREY}Worker${C_RESET}  ${UI_DET_WORKER:-…}"
  _ui_row ""
  _ui_row "${C_GREY}Actions${C_RESET}"
  local i
  for i in "${!UI_MENU_LABELS[@]}"; do
    if (( i == UI_MSEL )); then _ui_sel_row "  > ${UI_MENU_LABELS[$i]}"
    else _ui_row "    ${UI_MENU_LABELS[$i]}"; fi
  done
  _ui_row ""
  _ui_row "${C_GREY}↑/↓ move · enter run · esc back · q quit${C_RESET}"
}

# _ui_load_site_detail — read the selected site's config (one SSH round-trip)
# into UI_DET_* for the menu header: framework, TLS, scheduler and worker.
_ui_load_site_detail() {
  UI_DET_FW="…"; UI_DET_TLS="…"; UI_DET_SCHED="…"; UI_DET_WORKER="…"
  if ! registry_exists "$UI_SERVER"; then
    UI_DET_FW="(no server)"; UI_DET_TLS="-"; UI_DET_SCHED="-"; UI_DET_WORKER="-"; return
  fi
  ssh_use_server "$UI_SERVER"
  if site_load "$UI_DOMAIN" 2>/dev/null; then
    UI_DET_FW="$(framework_label "$SITE_FRAMEWORK")"
    [[ "$SITE_HTTPS" == 1 ]] && UI_DET_TLS="yes" || UI_DET_TLS="no"
    [[ "$SITE_SCHEDULER" == 1 ]] && UI_DET_SCHED="on" || UI_DET_SCHED="off"
    if [[ "$SITE_HORIZON" == 1 ]]; then
      UI_DET_WORKER="Horizon (${SITE_WORKER_PROCS:-auto})"
    elif [[ "$SITE_QUEUE" == 1 ]]; then
      if [[ "$SITE_FRAMEWORK" == symfony ]]; then UI_DET_WORKER="Messenger (${SITE_WORKER_PROCS:-2})"
      else UI_DET_WORKER="Queue (${SITE_WORKER_PROCS:-2})"; fi
    else
      UI_DET_WORKER="none"
    fi
  else
    UI_DET_FW="(missing)"; UI_DET_TLS="-"; UI_DET_SCHED="-"; UI_DET_WORKER="-"
  fi
}

# --- actions --------------------------------------------------------------

# _ui_run <title> <command...> — suspend the UI, run a real command, resume.
_ui_run() {
  local title="$1"; shift
  _ui_leave_screen
  printf '\n%s── %s ──%s\n\n' "$C_BOLD" "$title" "$C_RESET"
  "$@"; local rc=$?
  printf '\n%sPress any key to return to the panel…%s' "$C_GREY" "$C_RESET"
  local _k; IFS= read -rsn1 _k
  _ui_enter_screen
  return "$rc"
}

# _ui_shell <domain> — open an interactive login shell in the site's app root.
_ui_shell() {
  local d="$1" server
  server="$(registry_resolve_for_site "$d" "${OPT_SERVER:-}")" || { err "No server for ${d}."; return 1; }
  ssh_use_server "$server"
  site_load "$d" >/dev/null 2>&1 || true
  local root="${SITE_APP_ROOT:-/var/www}"
  info "Shell on ${server}:${root} — type 'exit' to return."
  ssh_app_interactive "$root" 'exec ${SHELL:-bash} -l'
}

_ui_menu_action() {
  local d="$UI_DOMAIN"
  case "$1" in
    0) _ui_run "Deploy ${d}"        cmd_update   "$d"; _ui_load_status; _ui_load_site_detail;;
    1) _ui_run "Logs ${d}"          cmd_logs     "$d";;
    2) _ui_run "Roll back ${d}"     cmd_rollback "$d"; _ui_load_status; _ui_load_site_detail;;
    3) _ui_run "Renew TLS ${d}"     cmd_ssl      "$d"; _ui_load_status; _ui_load_site_detail;;
    4) _ui_run "Audit ${d}"         cmd_audit    "$d";;
    5) _ui_run "Env ${d}"           cmd_env      "$d" show;;
    6) _ui_run "Scale workers ${d}" cmd_worker   "$d" scale; _ui_load_site_detail;;
    7) # Toggle scheduler based on the current state.
       if [[ "$UI_DET_SCHED" == on ]]; then _ui_run "Disable scheduler ${d}" cmd_scheduler "$d" off
       else _ui_run "Enable scheduler ${d}" cmd_scheduler "$d" on; fi
       _ui_load_site_detail;;
    8) _ui_run "Shell ${d}"         _ui_shell    "$d";;
    9) UI_VIEW=sites;;
  esac
}

_ui_help() {
  _ui_run "Help" cat <<'HELP'
server ui — terminal control panel

  ↑ / k      move up           ↓ / j      move down
  enter / →  open / run        esc / ←    back
  a          add a site        r          refresh the site list
  q          quit              ?          this help

Pick a site to deploy it, tail its logs, roll back, renew TLS,
run the security audit, view its .env, or open a shell on its server.
HELP
}

# --- input handlers -------------------------------------------------------

_ui_load_sites() {
  UI_SITES=()
  UI_STATUS=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    UI_SITES+=("$line")
  done <<< "$(index_all)"
  (( ${#UI_SITES[@]} == 0 )) && UI_SEL=0
  (( UI_SEL >= ${#UI_SITES[@]} && ${#UI_SITES[@]} > 0 )) && UI_SEL=$(( ${#UI_SITES[@]} - 1 ))
}

# _ui_load_status — fill UI_STATUS[i] ("framework<TAB>tls<TAB>last") for each
# site by reading its remote config + deploy history (same data as `server
# list`). One SSH auth per server thanks to ControlMaster; blocks while loading.
_ui_load_status() {
  UI_STATUS=()
  local i row domain server fw tls last cur status
  for i in "${!UI_SITES[@]}"; do
    row="${UI_SITES[$i]}"; domain="${row%%$'\t'*}"; server="${row#*$'\t'}"
    fw="?"; tls="-"; last="never"
    if registry_exists "$server"; then
      ssh_use_server "$server"
      if site_load "$domain" 2>/dev/null; then
        fw="$(framework_label "$SITE_FRAMEWORK")"
        [[ "$SITE_HTTPS" == "1" ]] && tls="yes" || tls="no"
        cur="$(history_current "$domain" 2>/dev/null)"
        if [[ -n "$cur" ]]; then
          status="$(history_get "$domain" "$cur" status 2>/dev/null)"
          last="${cur} (${status:-?})"
        fi
      else
        fw="(missing)"
      fi
    else
      fw="(no server)"
    fi
    UI_STATUS[$i]="${fw}"$'\t'"${tls}"$'\t'"${last}"
  done
}

# returns non-zero to quit the app
_ui_key_sites() {
  local k="$1" n=${#UI_SITES[@]}
  UI_MSG=""
  case "$k" in
    up)    (( n )) && UI_SEL=$(( (UI_SEL - 1 + n) % n ));;
    down)  (( n )) && UI_SEL=$(( (UI_SEL + 1) % n ));;
    enter|right)
      (( n )) || { UI_MSG="No sites yet — press 'a' to add one."; return 0; }
      local row="${UI_SITES[$UI_SEL]}"
      UI_DOMAIN="${row%%$'\t'*}"; UI_SERVER="${row#*$'\t'}"
      UI_VIEW=menu; UI_MSEL=0
      UI_DET_FW="…"; UI_DET_TLS="…"; UI_DET_SCHED="…"; UI_DET_WORKER="…"
      _ui_render; _ui_load_site_detail;;
    refresh) _ui_load_sites; UI_MSG="Loading status…"; _ui_render; _ui_load_status; UI_MSG="Refreshed.";;
    help)    _ui_help;;
    char:a)  _ui_run "Add a site" cmd_add; _ui_load_sites;;
    quit)    return 1;;
    *) :;;
  esac
  return 0
}

_ui_key_menu() {
  local k="$1" n=${#UI_MENU_LABELS[@]}
  case "$k" in
    up)            UI_MSEL=$(( (UI_MSEL - 1 + n) % n ));;
    down)          UI_MSEL=$(( (UI_MSEL + 1) % n ));;
    back|left)     UI_VIEW=sites;;
    enter|right)   _ui_menu_action "$UI_MSEL";;
    quit)          return 1;;
    *) :;;
  esac
  return 0
}

# --- entry point ----------------------------------------------------------

cmd_ui() {
  json_mode && die "'server ui' is interactive and isn't available in --json mode."
  [[ -t 0 && -t 1 ]] || die "'server ui' needs an interactive terminal."

  # This is a long-running interactive loop: many of its commands legitimately
  # return non-zero (key reads, arithmetic that evaluates to 0, a false `((…))`
  # guard). The engine runs under `set -e` + a global ERR trap that would abort
  # on the first such case, so opt this command out for its lifetime.
  set +e
  trap - ERR

  config_init_local
  UI_VIEW=sites; UI_SEL=0; UI_MSEL=0; UI_MSG=""
  UI_DOMAIN=""; UI_SERVER=""
  UI_DET_FW=""; UI_DET_TLS=""; UI_DET_SCHED=""; UI_DET_WORKER=""
  UI_SITES=(); UI_STATUS=()
  _ui_load_sites

  _ui_enter_screen
  trap '_ui_leave_screen' INT TERM EXIT

  # First paint shows the list immediately with "..." placeholders, then we
  # fetch live status (framework / TLS / last deploy) over SSH and repaint.
  if (( ${#UI_SITES[@]} > 0 )); then
    UI_MSG="Loading status…"; _ui_render
    _ui_load_status; UI_MSG=""
  fi

  local key
  while :; do
    _ui_render
    key="$(_ui_read_key)"
    if [[ "$UI_VIEW" == menu ]]; then
      _ui_key_menu "$key" || break
    else
      _ui_key_sites "$key" || break
    fi
  done

  _ui_leave_screen
  trap - INT TERM EXIT
}
