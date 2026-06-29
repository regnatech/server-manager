# shellcheck shell=bash
#
# logs.sh — `server logs <site> [nginx|php|laravel|queue] [-n N] [-f]`
# Tail the relevant remote log. Use -f to follow live (interactive).

cmd_logs() {
  local domain="" type="" lines=120 follow=0
  while (( $# )); do
    case "$1" in
      -n|--lines) lines="$2"; shift 2;;
      -f|--follow) follow=1; shift;;
      nginx|php|laravel|queue) type="$1"; shift;;
      -*) die "Unknown option '$1'.";;
      *) [[ -z "$domain" ]] && domain="$1" || type="$1"; shift;;
    esac
  done
  [[ -n "$domain" ]] || die "Usage: server logs <site> [nginx|php|laravel|queue] [-n N] [-f]"

  local server; server="$(registry_resolve_for_site "$domain" "$OPT_SERVER")"
  ssh_use_server "$server"
  site_load "$domain" || die "Site '${domain}' is not registered on '${server}'."

  # Default log type by framework.
  if [[ -z "$type" ]]; then
    _is_laravel_like "$SITE_FRAMEWORK" && type="laravel" || type="nginx"
  fi

  # Resolve candidate paths (the remote picks the first that exists).
  local candidates
  case "$type" in
    nginx)   candidates="/var/log/nginx/${domain}.error.log /var/log/nginx/error.log";;
    php)     candidates="/var/log/php${SITE_PHP_VERSION}-fpm.log /var/log/php-fpm.log /var/log/php-fpm/www-error.log";;
    laravel) candidates="${SITE_APP_ROOT}/storage/logs/laravel.log";;
    queue)   candidates="${SITE_APP_ROOT}/storage/logs/horizon.log ${SITE_APP_ROOT}/storage/logs/worker.log ${SITE_APP_ROOT}/storage/logs/laravel.log";;
  esac

  local pick="for f in ${candidates}; do [ -f \"\$f\" ] && { echo \"\$f\"; break; }; done"
  local remote_file; remote_file="$(ssh_exec "$pick")"
  [[ -n "$remote_file" ]] || die "No ${type} log found for ${domain} (looked in: ${candidates})."

  if json_mode; then
    ui_emit "{\"t\":\"data\",$(json_kv_string kind logs_meta),$(json_kv_raw value "{$(json_kv_string type "$type"),$(json_kv_string file "$remote_file")}")}"
    if [[ "$follow" == 1 ]]; then
      # Live tail: one log event per line, indefinitely (the UI closes it).
      ssh_exec "tail -n ${lines} -F $(shq "$remote_file")" 2>/dev/null | while IFS= read -r line; do
        ui_emit "{\"t\":\"log\",$(json_kv_string level info),$(json_kv_string msg "$line")}"
      done
    else
      local out; out="$(ssh_exec "tail -n ${lines} $(shq "$remote_file")" 2>/dev/null || true)"
      ui_emit "{\"t\":\"data\",$(json_kv_string kind logs),$(json_kv_raw value "{$(json_kv_string type "$type"),$(json_kv_string file "$remote_file"),$(json_kv_raw lines "$(_logs_lines_json "$out")")}")}"
    fi
    return
  fi

  info "Tailing ${C_BOLD}${remote_file}${C_RESET} on ${server}  ${C_GREY}(${type})${C_RESET}"
  if [[ "$follow" == 1 ]]; then
    ssh_interactive "tail -n ${lines} -f $(shq "$remote_file")"
  else
    ssh_exec "tail -n ${lines} $(shq "$remote_file")"
  fi
}

# _logs_lines_json <text> -> JSON array of the lines (preserving order)
_logs_lines_json() {
  local out="[" first=1 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    (( first )) || out+=","
    out+="$(json_str "$line")"; first=0
  done <<<"$1"
  out+="]"
  printf '%s' "$out"
}
