# shellcheck shell=bash
#
# notify.sh — outbound notifications (Slack / Telegram).
#
# notify_send is called by deploys (and can be called by anything) to post a
# short message to whatever channels the user configured with `server notify
# set …`. Channels are best-effort: a failing webhook never breaks a deploy.
#
# Config lives in the global prefs (control side), set via config.sh:
#   notify_slack_url, notify_telegram_token, notify_telegram_chat
#
# The payload builders are pure (no network) so they can be unit-tested.

# _notify_emoji <status> -> a leading glyph for the message
_notify_emoji() {
  case "$1" in
    success|ok)   printf '✅';;
    failure|fail|error) printf '❌';;
    warn|warning) printf '⚠️';;
    *)            printf 'ℹ️';;
  esac
}

# _notify_format <status> <title> <text> -> "<emoji> <title>\n<text>"
_notify_format() {
  local e; e="$(_notify_emoji "$1")"
  if [[ -n "$3" ]]; then printf '%s %s\n%s' "$e" "$2" "$3"; else printf '%s %s' "$e" "$2"; fi
}

# _notify_slack_payload <text> -> Slack incoming-webhook JSON body
_notify_slack_payload() {
  printf '{"text":%s}' "$(json_str "$1")"
}

# notify_configured -> 0 if at least one channel is set up
notify_configured() {
  [[ -n "$(global_get notify_slack_url)" ]] && return 0
  [[ -n "$(global_get notify_telegram_token)" && -n "$(global_get notify_telegram_chat)" ]] && return 0
  return 1
}

# _notify_slack <url> <text>
_notify_slack() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS -m 10 -X POST -H 'Content-type: application/json' \
    --data "$(_notify_slack_payload "$2")" "$1" >/dev/null 2>&1 || true
}

# _notify_telegram <token> <chat> <text>
_notify_telegram() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS -m 10 "https://api.telegram.org/bot${1}/sendMessage" \
    --data-urlencode "chat_id=${2}" \
    --data-urlencode "text=${3}" >/dev/null 2>&1 || true
}

# notify_send <status> <title> <text> — fan out to every configured channel.
# Never fails: returns 0 regardless so callers can fire-and-forget.
notify_send() {
  local status="$1" title="$2" text="${3:-}"
  local msg; msg="$(_notify_format "$status" "$title" "$text")"
  local slack tg_token tg_chat
  slack="$(global_get notify_slack_url)"
  tg_token="$(global_get notify_telegram_token)"
  tg_chat="$(global_get notify_telegram_chat)"
  [[ -n "$slack" ]] && _notify_slack "$slack" "$msg"
  [[ -n "$tg_token" && -n "$tg_chat" ]] && _notify_telegram "$tg_token" "$tg_chat" "$msg"
  return 0
}
