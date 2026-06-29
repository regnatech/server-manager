# shellcheck shell=bash
#
# php.sh — `server php <site> [set <version> | <args...>]`
#   * no args            → show the configured PHP version & FPM socket
#   * set <version>      → switch the site's PHP version (re-provision + restart)
#   * <args...>          → run php/artisan on the site, e.g.
#                          server php clicketta artisan queue:work --once
#                          server php clicketta -v

cmd_php() {
  local domain="${1:-}"; [[ -n "$domain" ]] || die "Usage: server php <site> [set <version> | <args...>]"
  shift || true

  local server; server="$(registry_resolve_for_site "$domain" "$OPT_SERVER")"
  ssh_use_server "$server"
  site_load "$domain" || die "Site '${domain}' is not registered on '${server}'."

  is_php_framework "$SITE_FRAMEWORK" || warn "'${domain}' is a ${SITE_FRAMEWORK} site — PHP may not apply."

  # No args → show current.
  if (( $# == 0 )); then
    section "PHP — ${domain}"
    say "  version : ${C_BOLD}${SITE_PHP_VERSION:-unknown}${C_RESET}"
    say "  socket  : ${SITE_PHP_SOCKET:-unknown}"
    local live; live="$(ssh_app_exec "$SITE_APP_ROOT" 'php -v 2>/dev/null | head -1' || true)"
    [[ -n "$live" ]] && say "  runtime : ${live}"
    return 0
  fi

  # Switch version.
  if [[ "$1" == "set" ]]; then
    local ver="${2:-}"; [[ -n "$ver" ]] || die "Usage: server php ${domain} set <version> (e.g. 8.3)"
    _php_switch "$domain" "$ver" "$server"
    return $?
  fi

  # Otherwise run php with the given args in the app root (interactive),
  # using the configured version's binary when available.
  local args="" a
  for a in "$@"; do args+=" $(shq "$a")"; done
  local prelude; prelude="$(_php_bin_prelude "$SITE_PHP_VERSION")"
  ssh_app_interactive "$SITE_APP_ROOT" "${prelude} \$PHP${args}"
}

# _php_switch <domain> <version> <server>
_php_switch() {
  local domain="$1" ver="$2" server="$3"
  banner "php set ${ver} — ${domain}"

  # Find the matching fpm socket for the new version.
  local sock
  sock="$(ssh_exec "for s in /run/php/php${ver}-fpm.sock /run/php-fpm/php${ver}.sock; do [ -S \"\$s\" ] && { echo \"\$s\"; break; }; done")"
  if [[ -z "$sock" ]]; then
    warn "No php-fpm socket found for PHP ${ver} (is php${ver}-fpm installed and running?)."
    sock="$(ask_required "PHP-FPM socket path" "/run/php/php${ver}-fpm.sock")"
  fi

  step "Updating site config to PHP ${ver}" _php_persist "$domain" "$ver" "$sock" \
    || die "Failed to update site config."

  # Re-render and install the nginx vhost with the new socket.
  site_load "$domain"
  local rendered; rendered="$(nginx_render "$domain" "$SITE_ROOT" "$SITE_FRAMEWORK" "$sock" "$SITE_UPSTREAM")"
  step "Re-provisioning nginx" _add_install_nginx "$domain" "$rendered" || die "nginx reload failed."
  step "Restarting PHP-FPM ${ver}" deploy_restart_php_fpm "$ver" || warn "Could not restart php-fpm."
  ok "Site '${domain}' now uses PHP ${ver}."
}

_php_persist() {
  local domain="$1" ver="$2" sock="$3"
  remote_site_load "$domain" \
    | awk -v v="$ver" -v s="$sock" '
        /^php_version=/{print "php_version=" v; pv=1; next}
        /^php_socket=/ {print "php_socket=" s; ps=1; next}
        {print}
        END{if(!pv)print "php_version=" v; if(!ps)print "php_socket=" s}' \
    | remote_site_write "$domain"
}
