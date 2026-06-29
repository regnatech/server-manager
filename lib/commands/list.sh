# shellcheck shell=bash
#
# list.sh — `server list`
# Show every managed site (from the local index) with its framework, branch,
# TLS state and last deploy. Sites are grouped by server.

cmd_list() {
  local entries; entries="$(index_all)"
  if [[ -z "$entries" ]]; then
    info "No sites yet. Add one with 'server add'."
    return 0
  fi

  section "Managed sites"
  printf '%s%-26s %-10s %-12s %-5s %-18s%s\n' "$C_BOLD" \
    "DOMAIN" "SERVER" "FRAMEWORK" "TLS" "LAST DEPLOY" "$C_RESET" >&2

  local domain server cur status fw branch tls last
  while IFS=$'\t' read -r domain server || [[ -n "$domain" ]]; do
    [[ -z "$domain" ]] && continue
    fw="?"; branch=""; tls="-"; last="never"
    if registry_exists "$server"; then
      ssh_use_server "$server"
      if site_load "$domain" 2>/dev/null; then
        fw="$(framework_label "$SITE_FRAMEWORK")"
        branch="$SITE_GIT_BRANCH"
        [[ "$SITE_HTTPS" == "1" ]] && tls="yes" || tls="no"
        cur="$(history_current "$domain" 2>/dev/null)"
        if [[ -n "$cur" ]]; then
          status="$(history_get "$domain" "$cur" status 2>/dev/null)"
          last="${cur} (${status:-?})"
        fi
      else
        fw="(not found)"
      fi
    else
      server="${server} (unknown)"
    fi
    printf '%-26s %s%-10s%s %-12s %-5s %s%-18s%s\n' \
      "$domain" "$C_CYAN" "$server" "$C_RESET" "$fw" "$tls" "$C_GREY" "$last" "$C_RESET" >&2
  done <<<"$entries"
}
