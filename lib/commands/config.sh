# shellcheck shell=bash
#
# config.sh — `server config <list|get|set>`
#
# A small, schema-driven settings store (global prefs on the control side). The
# desktop Settings screen renders a form from `config list` and saves each field
# with `config set`. Secrets (tokens) are write-only over the wire: `list`
# reports whether they're set, never their value.
#
# Add a key here and it appears in the CLI and --json output automatically.

# key | label | section | type(string|secret|bool)
_CONFIG_SCHEMA=(
  "le_email|Let's Encrypt email|general|string"
  "default_server|Default server|general|string"
  "git_author_name|Git author name|git|string"
  "git_author_email|Git author email|git|string"
  "github_token|GitHub token (for pull requests)|git|secret"
  "git_default_base|Default PR base branch|git|string"
  "notify_slack_url|Slack incoming-webhook URL|notifications|string"
  "notify_telegram_token|Telegram bot token|notifications|secret"
  "notify_telegram_chat|Telegram chat id|notifications|string"
)

# _config_field <key> <n> -> the n-th pipe field of the schema row for <key>
_config_field() {
  local key="$1" n="$2" row
  for row in "${_CONFIG_SCHEMA[@]}"; do
    [[ "${row%%|*}" == "$key" ]] || continue
    printf '%s' "$row" | cut -d'|' -f"$n"; return 0
  done
  return 1
}

_config_known() { _config_field "$1" 1 >/dev/null 2>&1; }

cmd_config() {
  local sub="${1:-list}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    list) _config_list;;
    get)  local k="${1:-}"; [[ -n "$k" ]] || die "Usage: server config get <key>"
          printf '%s\n' "$(global_get "$k")";;
    set)  _config_set "$@";;
    *) die "Usage: server config <list|get <key>|set <key> <value>>";;
  esac
}

_config_set() {
  local key="${1:-}" value="${2:-}"
  [[ -n "$key" ]] || die "Usage: server config set <key> <value>"
  _config_known "$key" || die "Unknown setting '${key}'. See 'server config list'."
  global_set "$key" "$value"
  json_mode && { ui_emit "{\"t\":\"data\",$(json_kv_string kind config_set),$(json_kv_raw value "{$(json_kv_string key "$key")}")}"; return; }
  ok "Saved ${key}."
}

_config_list() {
  if json_mode; then
    local items="[" first=1 row key label section type val set_b
    for row in "${_CONFIG_SCHEMA[@]}"; do
      key="$(printf '%s' "$row" | cut -d'|' -f1)"
      label="$(printf '%s' "$row" | cut -d'|' -f2)"
      section="$(printf '%s' "$row" | cut -d'|' -f3)"
      type="$(printf '%s' "$row" | cut -d'|' -f4)"
      val="$(global_get "$key")"
      set_b=false; [[ -n "$val" ]] && set_b=true
      (( first )) || items+=","
      items+="{$(json_kv_string key "$key"),$(json_kv_string label "$label"),$(json_kv_string section "$section"),$(json_kv_string type "$type"),$(json_kv_raw set "$set_b")"
      # Echo the value for non-secret fields only.
      [[ "$type" != "secret" ]] && items+=",$(json_kv_string value "$val")"
      items+="}"
      first=0
    done
    items+="]"
    ui_emit "{\"t\":\"data\",$(json_kv_string kind config),$(json_kv_raw items "$items")}"
    return
  fi
  section "Settings"
  local row key label type val
  for row in "${_CONFIG_SCHEMA[@]}"; do
    key="$(printf '%s' "$row" | cut -d'|' -f1)"
    label="$(printf '%s' "$row" | cut -d'|' -f2)"
    type="$(printf '%s' "$row" | cut -d'|' -f4)"
    val="$(global_get "$key")"
    if [[ "$type" == "secret" ]]; then
      [[ -n "$val" ]] && say "  ${label}: ${C_GREEN}set${C_RESET}" || say "  ${label}: ${C_GREY}not set${C_RESET}"
    else
      say "  ${label}: ${val:-${C_GREY}—${C_RESET}}"
    fi
  done
}
