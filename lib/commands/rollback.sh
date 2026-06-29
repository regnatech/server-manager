# shellcheck shell=bash
#
# rollback.sh — `server rollback <site> [target]`
#
# Reverts the most recent deploy by default: git is reset to the commit the
# site was on *before* that deploy, and the .env + database are restored from
# the snapshot taken just before it. An explicit <target> (a git ref such as a
# sha, tag, or HEAD~1) overrides only the code target; data is still restored
# from the most recent backup so schema and code stay consistent.

cmd_rollback() {
  local domain="${1:-}" target="${2:-}"
  [[ -n "$domain" ]] || die "Usage: server rollback <site> [git-ref] [--server <name>]"

  local server; server="$(registry_resolve_for_site "$domain" "$OPT_SERVER")"
  ssh_use_server "$server"

  banner "rollback — ${domain} @ ${server}"
  site_load "$domain" || die "Site '${domain}' is not registered on '${server}'."

  local app_root="$SITE_APP_ROOT" fw="$SITE_FRAMEWORK" php="$SITE_PHP_VERSION"
  _UPD_APP_ROOT="$app_root"; _UPD_PHP="$php"; _UPD_MAINT=0
  local has_git=0; [[ -n "$SITE_GIT_REMOTE" ]] && has_git=1

  # Find the deploy to undo (latest, successful or not).
  local latest; latest="$(history_current "$domain")"
  if [[ -z "$latest" ]]; then
    # Take the first line without `| head` (which can SIGPIPE the ssh producer
    # under pipefail). Capture all, then slice the first line.
    latest="$(history_list "$domain")"; latest="${latest%%$'\n'*}"
  fi
  [[ -n "$latest" ]] || die "No deploy history for '${domain}' — nothing to roll back."

  local backup_path git_default
  backup_path="$(history_get "$domain" "$latest" backup_path)"
  git_default="$(history_get "$domain" "$latest" sha_before)"
  [[ -n "$target" ]] || target="$git_default"

  section "Rollback plan"
  info "Reverting deploy ${C_BOLD}${latest}${C_RESET}"
  [[ "$has_git" == 1 ]] && say "  code     → git ref ${C_BOLD}${target:-<unknown>}${C_RESET}"
  say "  data     → snapshot ${C_BOLD}${backup_path:-<none>}${C_RESET}"
  if [[ "$has_git" == 1 && -z "$target" ]]; then
    die "Could not determine a git target to roll back to. Pass one explicitly: server rollback ${domain} <git-ref>"
  fi
  confirm "Proceed with rollback?" "n" || die "Aborted."

  local ts; ts="$(timestamp)"
  local t_start; t_start="$(_ui_now)"

  section "Rollback"
  # Maintenance mode.
  if _is_laravel_like "$fw"; then
    step "Enabling maintenance mode" deploy_laravel_down "$app_root" "$php" \
      || _rollback_abort "Could not enable maintenance mode."
    _UPD_MAINT=1
  fi

  # Code.
  if [[ "$has_git" == 1 ]]; then
    step "Resetting code to ${target}" deploy_git_reset "$app_root" "$target" \
      || _rollback_abort "git reset failed."
  fi

  # Data.
  if [[ -n "$backup_path" ]]; then
    step "Restoring .env" deploy_restore_env "$app_root" "$backup_path" || warn ".env restore reported a problem."
    if _is_laravel_like "$fw"; then
      step "Restoring database" deploy_restore_db "$app_root" "$fw" "$backup_path" || warn "Database restore reported a problem."
    fi
  else
    warn "No backup snapshot recorded for this deploy — skipping data restore."
  fi

  # Dependencies + caches.
  step "Reinstalling Composer dependencies" deploy_composer "$app_root" \
    || _rollback_abort "composer install failed."
  if [[ -n "$SITE_NODE_PM" ]]; then
    step "Rebuilding frontend (${SITE_NODE_PM})" deploy_node "$app_root" "$SITE_NODE_PM" || warn "Frontend build reported a problem."
  fi
  if _is_laravel_like "$fw"; then
    step "Rebuilding caches" deploy_laravel_optimize "$app_root" "$php" || warn "Cache rebuild reported a problem."
  fi

  # Services.
  section "Services"
  if is_php_framework "$fw"; then
    step "Restarting PHP-FPM" deploy_restart_php_fpm "$php" || warn "PHP-FPM restart reported a problem."
  fi
  [[ "$SITE_QUEUE" == 1 || "$SITE_HORIZON" == 1 ]] && { step "Restarting supervisor" deploy_restart_supervisor || true; }
  [[ "$SITE_QUEUE" == 1 ]] && { step "Restarting queue workers" deploy_queue_restart "$app_root" "$php" || true; }
  [[ "$SITE_HORIZON" == 1 ]] && { step "Restarting Horizon" deploy_horizon_terminate "$app_root" "$php" || true; }

  # Online.
  if _is_laravel_like "$fw"; then
    step "Disabling maintenance mode" deploy_laravel_up "$app_root" "$php" \
      || _rollback_abort "Could not disable maintenance mode."
    _UPD_MAINT=0
  fi

  # Health check.
  section "Health check"
  local want_php=0 want_sup=0
  is_php_framework "$fw" && want_php=1
  [[ "$SITE_QUEUE" == 1 || "$SITE_HORIZON" == 1 ]] && want_sup=1
  local hc rc=0
  hc="$(deploy_healthcheck "$domain" "$SITE_HTTPS" "$want_php" "$want_sup" "${SITE_REDIS:-0}")" || rc=$?
  _render_healthcheck "$hc"

  local t_end; t_end="$(_ui_now)"; local dur; dur="$(_ui_elapsed "$t_start" "$t_end")"
  local status="ok"; [[ $rc -ne 0 ]] && status="degraded"
  history_record "$domain" "$ts" "$latest" "$target" "$backup_path" "rollback-$status" "$dur" || true

  report_box "Rollback ${status}: ${domain}" \
    "Server      : ${server}" \
    "Reverted    : deploy ${latest}" \
    "${target:+Code now at : ${target}}" \
    "Completed in: ${dur}s"
}

_rollback_abort() {
  err "$1"
  if [[ "$_UPD_MAINT" == 1 && -n "$_UPD_APP_ROOT" ]]; then
    warn "Bringing the site back online…"
    deploy_laravel_up "$_UPD_APP_ROOT" "$_UPD_PHP" >/dev/null 2>&1 || true
  fi
  err "Rollback aborted."
  exit 1
}
