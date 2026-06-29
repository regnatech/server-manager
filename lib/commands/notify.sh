# shellcheck shell=bash
#
# notify.sh — `server notify <set|test|status|off>`
#
# Configure where deploy/audit notifications go. Stored in the global prefs on
# the control side (so they apply across all servers).

cmd_notify() {
  local sub="${1:-status}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    status) _notify_status;;
    test)   _notify_cmd_test;;
    off)    global_set notify_slack_url ""; global_set notify_telegram_token ""; global_set notify_telegram_chat ""
            ok "Notifications disabled.";;
    set)    _notify_cmd_set "$@";;
    *) die "Usage: server notify <status|set <slack|telegram> …|test|off>";;
  esac
}

_notify_status() {
  local slack tg sb=false tb=false
  slack="$(global_get notify_slack_url)"; tg="$(global_get notify_telegram_token)"
  [[ -n "$slack" ]] && sb=true
  [[ -n "$tg" && -n "$(global_get notify_telegram_chat)" ]] && tb=true
  if json_mode; then
    ui_emit "{\"t\":\"data\",$(json_kv_string kind notify),$(json_kv_raw value "{$(json_kv_raw slack "$sb"),$(json_kv_raw telegram "$tb")}")}"
    return
  fi
  section "Notifications"
  [[ "$sb" == true ]] && ok "Slack: configured" || info "Slack: not configured"
  [[ "$tb" == true ]] && ok "Telegram: configured" || info "Telegram: not configured"
  notify_configured || say "  ${C_GREY}Set one up: server notify set slack <webhook-url>${C_RESET}"
}

# server notify set slack <webhook-url>
# server notify set telegram <bot-token> <chat-id>
_notify_cmd_set() {
  local kind="${1:-}"; [[ $# -gt 0 ]] && shift
  case "$kind" in
    slack)
      local url="${1:-}"; [[ -n "$url" ]] || url="$(ask_required "Slack incoming-webhook URL")"
      global_set notify_slack_url "$url"; ok "Slack webhook saved.";;
    telegram)
      local token="${1:-}" chat="${2:-}"
      [[ -n "$token" ]] || token="$(ask_required "Telegram bot token")"
      [[ -n "$chat" ]]  || chat="$(ask_required "Telegram chat id")"
      global_set notify_telegram_token "$token"; global_set notify_telegram_chat "$chat"
      ok "Telegram bot saved.";;
    *) die "Usage: server notify set <slack <url>|telegram <token> <chat-id>>";;
  esac
  if confirm "Send a test notification now?" "Y"; then _notify_cmd_test; fi
}

_notify_cmd_test() {
  notify_configured || die "No channel configured. Try: server notify set slack <webhook-url>"
  step "Sending test notification" notify_send info "server-manager" "Test notification — your channel works."
  ok "Sent (check your Slack/Telegram)."
}
