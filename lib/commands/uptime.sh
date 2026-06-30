# shellcheck shell=bash
#
# uptime.sh — `server uptime [site|--all]`
#
# HTTP health check of a site's public URL from the control side: status code,
# response time, up/down. Each check is appended to a local history log so the
# UI can chart availability over time.
#
# JSON: {"t":"data","kind":"uptime","items":[
#         {"domain","url","up":bool,"code":200,"ms":123}, ...]}

SRVMGR_UPTIME_DIR="${SRVMGR_UPTIME_DIR:-$SRVMGR_HOME/uptime}"

# _uptime_eval <"<http_code> <time_total_seconds>"> -> "code ms up"
# up=1 for 2xx/3xx, else 0. ms is integer milliseconds.
_uptime_eval() {
  printf '%s\n' "$1" | awk '{
    code=$1+0; ms=int(($2+0)*1000);
    up=(code>=200 && code<400)?1:0;
    printf "%d %d %d", code, ms, up
  }'
}

# _uptime_check <url> -> "code ms up"  (runs curl from the control side)
_uptime_check() {
  local url="$1" out
  if command -v curl >/dev/null 2>&1; then
    out="$(curl -s -o /dev/null -m 15 -w '%{http_code} %{time_total}' -L "$url" 2>/dev/null || echo '000 0')"
  else
    out="000 0"
  fi
  _uptime_eval "$out"
}

# _uptime_record <domain> <code> <ms> <up> — append to the history log.
_uptime_record() {
  mkdir -p "$SRVMGR_UPTIME_DIR" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\n' "$(timestamp)" "$2" "$3" "$4" >>"$SRVMGR_UPTIME_DIR/$1.log"
}

cmd_uptime() {
  local arg="${1:-}"
  local targets=()
  if [[ "$arg" == "--all" || -z "$arg" ]]; then
    local d s
    while IFS=$'\t' read -r d s || [[ -n "$d" ]]; do [[ -n "$d" ]] && targets+=("$d"); done <<<"$(index_all)"
  else
    targets=("$arg")
  fi
  [[ ${#targets[@]} -gt 0 ]] || die "No sites to check. Add one with 'server add'."

  json_mode || section "Uptime"
  local items="[" first=1 domain server proto url code ms up
  for domain in "${targets[@]}"; do
    server="$(index_get_server "$domain")"
    proto="http"
    if registry_exists "$server"; then
      ssh_use_server "$server" 2>/dev/null || true
      site_load "$domain" 2>/dev/null && [[ "$SITE_HTTPS" == "1" ]] && proto="https"
    fi
    url="${proto}://${domain}"
    read -r code ms up <<<"$(_uptime_check "$url")"
    _uptime_record "$domain" "$code" "$ms" "$up"
    if json_mode; then
      local up_b=false; [[ "$up" == 1 ]] && up_b=true
      (( first )) || items+=","
      items+="{$(json_kv_string domain "$domain"),$(json_kv_string url "$url"),$(json_kv_raw up "$up_b"),$(json_kv_raw code "$code"),$(json_kv_raw ms "$ms")}"; first=0
    else
      if [[ "$up" == 1 ]]; then ok "${domain}  ${code}  ${ms}ms"; else err "${domain}  ${code}  DOWN"; fi
    fi
  done
  items+="]"
  if json_mode; then ui_emit "{\"t\":\"data\",$(json_kv_string kind uptime),$(json_kv_raw items "$items")}"; fi
}
