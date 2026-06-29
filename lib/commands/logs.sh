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

  info "Tailing ${C_BOLD}${remote_file}${C_RESET} on ${server}  ${C_GREY}(${type})${C_RESET}"
  if [[ "$follow" == 1 ]]; then
    ssh_interactive "tail -n ${lines} -f $(shq "$remote_file")"
  else
    ssh_exec "tail -n ${lines} $(shq "$remote_file")"
  fi
}
