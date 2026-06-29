# shellcheck shell=bash
#
# update.sh — `server update <site>`
#
# The intelligent, (near) zero-downtime deploy. Resolves the server from the
# site index, then runs the 12-step flow with per-step spinners, automatic
# backups, maintenance mode, cache rebuilds, service restarts, a health check
# and a timed report. If any step fails the site is brought back online before
# aborting, and the attempt is recorded as a failed deploy.

# Module-level state for failure recovery.
_UPD_MAINT=0
_UPD_APP_ROOT=""
_UPD_PHP=""

cmd_update() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || die "Usage: server update <site> [--server <name>]"

  local server; server="$(registry_resolve_for_site "$domain" "$OPT_SERVER")"
  ssh_use_server "$server"

  banner "update — ${domain} @ ${server}"

  # 1. Site must exist on the server (source of truth).
  site_load "$domain" || die "Site '${domain}' is not registered on '${server}'. Run 'server add' or 'server import' first."
  index_set "$domain" "$server"   # keep the local index fresh

  local app_root="$SITE_APP_ROOT" fw="$SITE_FRAMEWORK" php="$SITE_PHP_VERSION"
  _UPD_APP_ROOT="$app_root"; _UPD_PHP="$php"
  local has_git=0; [[ -n "$SITE_GIT_REMOTE" ]] && has_git=1

  local t_start; t_start="$(_ui_now)"
  local ts; ts="$(timestamp)"
  local backup_dir="${REMOTE_BACKUPS}/${domain}/${ts}"
  local sha_before="" sha_after=""

  # 2-3. Preflight: repo valid + clean working tree.
  if [[ "$has_git" == 1 ]]; then
    section "Preflight"
    step "Validating git repository" deploy_git_valid \
      || _update_abort "$domain" "$ts" "" "" "$backup_dir" "Not a git repo with an 'origin' remote at ${app_root}."
    if ! deploy_git_is_clean "$app_root"; then
      warn "The working tree at ${app_root} has uncommitted changes."
      confirm "Continue and risk losing them?" "n" \
        || _update_abort "$domain" "$ts" "" "" "$backup_dir" "Aborted due to local changes."
    else
      ok "Working tree is clean."
    fi
    sha_before="$(deploy_git_sha "$app_root")"
  fi

  # 4. Backup.
  section "Backup"
  step "Backing up .env, nginx config & database" \
    deploy_backup "$domain" "$app_root" "$fw" "$backup_dir" \
    || _update_abort "$domain" "$ts" "$sha_before" "" "$backup_dir" "Backup failed."

  section "Deploy"

  # 5. Maintenance mode (Laravel/Statamic).
  if _is_laravel_like "$fw"; then
    step "Enabling maintenance mode" deploy_laravel_down "$app_root" "$php" \
      || _update_abort "$domain" "$ts" "$sha_before" "" "$backup_dir" "Could not enable maintenance mode."
    _UPD_MAINT=1
  fi

  # 6. Pull code.
  if [[ "$has_git" == 1 ]]; then
    step "Pulling ${SITE_GIT_BRANCH:-main} from origin" \
      deploy_git_pull "$app_root" "${SITE_GIT_BRANCH:-main}" \
      || _update_abort "$domain" "$ts" "$sha_before" "" "$backup_dir" "git pull failed (not fast-forward?)."
    sha_after="$(deploy_git_sha "$app_root")"
  fi

  # 7. Composer.
  step "Installing Composer dependencies" deploy_composer "$app_root" \
    || _update_abort "$domain" "$ts" "$sha_before" "$sha_after" "$backup_dir" "composer install failed."

  # 8. Frontend build (auto, using the package manager from the lockfile).
  if [[ -n "$SITE_NODE_PM" ]]; then
    step "Building frontend (${SITE_NODE_PM})" deploy_node "$app_root" "$SITE_NODE_PM" \
      || _update_abort "$domain" "$ts" "$sha_before" "$sha_after" "$backup_dir" "Frontend build failed."
  fi

  # 9. Laravel migrate + cache rebuild.
  if _is_laravel_like "$fw"; then
    step "Running migrations" deploy_laravel_migrate "$app_root" "$php" \
      || _update_abort "$domain" "$ts" "$sha_before" "$sha_after" "$backup_dir" "Migrations failed."
    step "Rebuilding caches" deploy_laravel_optimize "$app_root" "$php" \
      || _update_abort "$domain" "$ts" "$sha_before" "$sha_after" "$backup_dir" "Cache rebuild failed."
  fi

  # 10. (Re)apply scheduler + workers, then restart services.
  section "Services"
  if _is_laravel_like "$fw"; then
    local slug; slug="$(slugify "$domain")"
    [[ "$SITE_SCHEDULER" == 1 ]] && { step "Ensuring scheduler cron" workers_install_scheduler "$slug" "$app_root" "$php" || true; }
    if [[ "$SITE_HORIZON" == 1 ]]; then
      step "Ensuring Horizon worker" _upd_ensure_worker "$slug" "$app_root" "$php" horizon || true
    elif [[ "$SITE_QUEUE" == 1 ]]; then
      step "Ensuring queue worker" _upd_ensure_worker "$slug" "$app_root" "$php" queue || true
    fi
  fi
  if _is_laravel_like "$fw" || is_php_framework "$fw"; then
    step "Restarting PHP-FPM" deploy_restart_php_fpm "$php" || warn "PHP-FPM restart reported a problem."
  fi
  if [[ "$SITE_QUEUE" == 1 || "$SITE_HORIZON" == 1 ]]; then
    step "Restarting supervisor programs" deploy_restart_supervisor || warn "Supervisor restart reported a problem."
  fi
  if [[ "$SITE_QUEUE" == 1 ]]; then
    step "Restarting queue workers" deploy_queue_restart "$app_root" "$php" || true
  fi
  if [[ "$SITE_HORIZON" == 1 ]]; then
    step "Restarting Horizon" deploy_horizon_terminate "$app_root" "$php" || true
  fi

  # 11. Bring the site back online.
  if _is_laravel_like "$fw"; then
    step "Disabling maintenance mode" deploy_laravel_up "$app_root" "$php" \
      || _update_abort "$domain" "$ts" "$sha_before" "$sha_after" "$backup_dir" "Could not disable maintenance mode."
    _UPD_MAINT=0
  fi

  # 12. Health check.
  section "Health check"
  local want_php=0 want_sup=0
  is_php_framework "$fw" && want_php=1
  [[ "$SITE_QUEUE" == 1 || "$SITE_HORIZON" == 1 ]] && want_sup=1
  local hc rc=0
  hc="$(deploy_healthcheck "$domain" "$SITE_HTTPS" "$want_php" "$want_sup" "${SITE_REDIS:-0}")" || rc=$?
  _render_healthcheck "$hc"

  # Record + report.
  local t_end; t_end="$(_ui_now)"
  local dur; dur="$(_ui_elapsed "$t_start" "$t_end")"
  local status="ok"; [[ $rc -ne 0 ]] && status="degraded"
  history_record "$domain" "$ts" "$sha_before" "$sha_after" "$backup_dir" "$status" "$dur" || true

  if [[ $rc -ne 0 ]]; then
    warn "Health check reported a critical problem — review the output above."
  fi
  report_box "Deploy ${status}: ${domain}" \
    "Server      : ${server}" \
    "${sha_before:+From commit : ${sha_before}}" \
    "${sha_after:+To commit   : ${sha_after}}" \
    "Backup      : ${backup_dir}" \
    "Completed in: ${dur}s"
}

# _upd_ensure_worker <slug> <app_root> <php> <mode> — install supervisor (if
# needed) and (re)write the worker program.
_upd_ensure_worker() {
  local slug="$1" app_root="$2" php="$3" mode="$4"
  workers_ensure_supervisor && workers_install_supervisor "$slug" "$app_root" "$php" "$mode"
}

# _render_healthcheck "<name|status|detail lines>"
_render_healthcheck() {
  local line name status detail
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *"|"* ]] || continue
    name="${line%%|*}"; line="${line#*|}"
    status="${line%%|*}"; detail="${line#*|}"
    case "$status" in
      ok)   ok   "${name}: ${detail}";;
      warn) warn "${name}: ${detail}";;
      *)    err  "${name}: ${detail}";;
    esac
  done <<<"$1"
}

# _update_abort <domain> <ts> <sha_before> <sha_after> <backup_dir> <message>
# Bring the site back online (if we took it down), record a failed deploy, and
# exit non-zero.
_update_abort() {
  local domain="$1" ts="$2" sb="$3" sa="$4" backup="$5" msg="$6"
  err "$msg"
  if [[ "$_UPD_MAINT" == 1 && -n "$_UPD_APP_ROOT" ]]; then
    warn "Bringing the site back online…"
    deploy_laravel_up "$_UPD_APP_ROOT" "$_UPD_PHP" >/dev/null 2>&1 || true
    _UPD_MAINT=0
  fi
  history_record "$domain" "$ts" "$sb" "$sa" "$backup" "failed" "0" >/dev/null 2>&1 || true
  err "Deploy aborted. A backup was saved at ${backup} — use 'server rollback ${domain}' if needed."
  exit 1
}
