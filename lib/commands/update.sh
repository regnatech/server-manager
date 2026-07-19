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
  [[ -n "$domain" ]] || die "Usage: server update <site> [--server <name>] | update --all [--framework <fw>]"
  if [[ "$domain" == "--all" ]]; then _update_all "$@"; return; fi

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

  # 2-3. Preflight: make sure the code is present (clone on first deploy), then
  #      check the working tree.
  local fresh_clone=0
  if [[ "$has_git" == 1 ]]; then
    section "Preflight"
    if deploy_git_valid "$app_root"; then
      ok "Git repository present."
      if ! deploy_git_is_clean "$app_root"; then
        warn "The working tree at ${app_root} has uncommitted changes."
        confirm "Continue and risk losing them?" "n" \
          || _update_abort "$domain" "$ts" "" "" "$backup_dir" "Aborted due to local changes."
      else
        ok "Working tree is clean."
      fi
      sha_before="$(deploy_git_sha "$app_root")"
    else
      # Never deployed yet — there's no checkout in ${app_root}. Bootstrap the
      # first deploy by cloning the configured remote.
      step "Cloning ${SITE_GIT_REMOTE} (${SITE_GIT_BRANCH:-main})" \
        deploy_git_clone "$app_root" "$SITE_GIT_REMOTE" "${SITE_GIT_BRANCH:-main}" \
        || _update_abort "$domain" "$ts" "" "" "$backup_dir" "Could not clone ${SITE_GIT_REMOTE} into ${app_root}."
      fresh_clone=1
    fi
  fi

  # 4. Backup.
  section "Backup"
  step "Backing up .env, nginx config & database" \
    deploy_backup "$domain" "$app_root" "$fw" "$backup_dir" \
    || _update_abort "$domain" "$ts" "$sha_before" "" "$backup_dir" "Backup failed."

  section "Deploy"

  # 5. Maintenance mode (Laravel/Statamic). Skipped on a first deploy: the site
  #    isn't live yet and artisan can't run before composer install.
  if _is_laravel_like "$fw" && [[ "$fresh_clone" == 0 ]]; then
    step "Enabling maintenance mode" deploy_laravel_down "$app_root" "$php" \
      || _update_abort "$domain" "$ts" "$sha_before" "" "$backup_dir" "Could not enable maintenance mode."
    _UPD_MAINT=1
  fi

  # 6. Pull code (a fresh clone is already at the tip, so only pull otherwise).
  if [[ "$has_git" == 1 ]]; then
    if [[ "$fresh_clone" == 0 ]]; then
      step "Pulling ${SITE_GIT_BRANCH:-main} from origin" \
        deploy_git_pull "$app_root" "${SITE_GIT_BRANCH:-main}" "$SITE_GIT_REMOTE" \
        || _update_abort "$domain" "$ts" "$sha_before" "" "$backup_dir" "Could not update from ${SITE_GIT_REMOTE} — check repo access (token scope / org SSO authorization / deploy key) and that '${SITE_GIT_BRANCH:-main}' fast-forwards."
    fi
    sha_after="$(deploy_git_sha "$app_root")"
  fi

  # 7. Composer. Self-healing: if the step fails (e.g. composer missing), install
  #    the toolchain and retry once before giving up.
  _deploy_try "Installing Composer dependencies" _diagnose_composer \
      -- deploy_composer "$app_root" \
    || _update_abort "$domain" "$ts" "$sha_before" "$sha_after" "$backup_dir" "composer install failed."

  # 7b. Auto-wire production services for Laravel/Symfony: scheduler + workers,
  #     and — for Laravel — install & run Horizon. Decides only what the user
  #     hasn't already configured, and persists the decision.
  if _is_laravel_like "$fw" || [[ "$fw" == symfony ]]; then
    section "Production setup"
    _update_autowire "$domain" "$app_root" "$php" "$fw"
  fi

  # 8. Frontend build. Always attempt it: deploy_node no-ops when there's no
  #    package.json, and auto-detects the package manager from the lockfile when
  #    the site config doesn't record one (e.g. first deploy after `add`).
  #    Self-healing: diagnose the failure and provision Node.js / the package
  #    manager as needed, then retry.
  _deploy_try "Building frontend${SITE_NODE_PM:+ (${SITE_NODE_PM})}" _diagnose_node \
      -- deploy_node "$app_root" "$SITE_NODE_PM" \
    || _update_abort "$domain" "$ts" "$sha_before" "$sha_after" "$backup_dir" "Frontend build failed."

  # 9. Database migrations + cache rebuild.
  if _is_laravel_like "$fw"; then
    step "Running migrations" deploy_laravel_migrate "$app_root" "$php" \
      || _update_abort "$domain" "$ts" "$sha_before" "$sha_after" "$backup_dir" "Migrations failed."
    step "Rebuilding caches" deploy_laravel_optimize "$app_root" "$php" \
      || _update_abort "$domain" "$ts" "$sha_before" "$sha_after" "$backup_dir" "Cache rebuild failed."
  elif [[ "$fw" == symfony ]]; then
    step "Running migrations" deploy_symfony_migrate "$app_root" "$php" \
      || _update_abort "$domain" "$ts" "$sha_before" "$sha_after" "$backup_dir" "Migrations failed."
    step "Warming cache" deploy_symfony_cache "$app_root" "$php" \
      || warn "Cache clear/warmup reported a problem."
  fi

  # 10. (Re)apply scheduler + workers, then restart services.
  section "Services"
  local slug; slug="$(slugify "$domain")"
  if _is_laravel_like "$fw" && [[ "$SITE_SCHEDULER" == 1 ]]; then
    step "Ensuring scheduler cron" workers_install_scheduler "$slug" "$app_root" "$php" || true
  fi
  if [[ "$SITE_HORIZON" == 1 ]]; then
    step "Ensuring Horizon worker" _upd_ensure_worker "$slug" "$app_root" "$php" horizon || true
  elif [[ "$SITE_QUEUE" == 1 ]]; then
    local wmode=queue; [[ "$fw" == symfony ]] && wmode=messenger
    step "Ensuring ${wmode} worker" _upd_ensure_worker "$slug" "$app_root" "$php" "$wmode" || true
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

  notify_send "$([[ "$status" == ok ]] && echo success || echo warn)" \
    "Deploy ${status}: ${domain}" \
    "Server ${server}${sha_after:+ · ${sha_after}} · ${dur}s" || true
}

# _upd_ensure_worker <slug> <app_root> <php> <mode> — install supervisor (if
# needed) and (re)write the worker program.
_upd_ensure_worker() {
  local slug="$1" app_root="$2" php="$3" mode="$4"
  workers_ensure_supervisor && workers_install_supervisor "$slug" "$app_root" "$php" "$mode"
}

# _update_autowire <domain> <app_root> <php> <framework>
#   Make a Laravel/Symfony site production-ready without manual setup. Only
#   decides what the operator hasn't already chosen (an empty flag), and
#   persists each decision to the remote site config so it sticks. Explicit
#   opt-outs are respected: scheduler=0 / horizon=0 / queue=1 are left alone.
#     * Laravel/Statamic — scheduler on; Horizon as the worker (Redis ensured,
#       and laravel/horizon installed automatically when the repo doesn't ship
#       it), unless the operator chose plain queue or disabled Horizon.
#     * Symfony — a messenger consumer worker when symfony/messenger is present.
_update_autowire() {
  local domain="$1" app_root="$2" php="$3" fw="$4"
  if _is_laravel_like "$fw"; then
    if [[ -z "$SITE_SCHEDULER" ]]; then
      SITE_SCHEDULER=1; remote_site_set_kv "$domain" scheduler 1 || true
      ok "Scheduler enabled (artisan schedule:run every minute)."
    fi
    # Horizon is the default Laravel worker unless plain queue was chosen or
    # Horizon was explicitly turned off.
    if [[ "$SITE_QUEUE" != 1 && "$SITE_HORIZON" != 0 ]]; then
      step "Ensuring Redis" toolchain_ensure_redis || warn "Could not ensure Redis (Horizon needs it)."
      if ! deploy_horizon_present "$app_root"; then
        step "Installing Laravel Horizon" deploy_install_horizon "$app_root" "$php" \
          || warn "Could not install Horizon — falling back to a plain queue worker."
      fi
      if deploy_horizon_present "$app_root"; then
        [[ "$SITE_HORIZON" == 1 ]] || { SITE_HORIZON=1; remote_site_set_kv "$domain" horizon 1 || true; }
        # Horizon only consumes the redis queue: make sure the app actually dispatches
        # there. Otherwise jobs pile up on the database/sync queue and are never handled
        # (a silent failure). Idempotent: only rewrites the .env when it isn't redis yet.
        local _qc; _qc="$(env_get_key "$app_root" QUEUE_CONNECTION 2>/dev/null | tr -d '[:space:]')"
        if [[ "$_qc" != redis ]]; then
          step "Setting QUEUE_CONNECTION=redis (required by Horizon)" \
            env_set_key "$app_root" QUEUE_CONNECTION redis \
            || warn "Could not set QUEUE_CONNECTION=redis — set it manually or Horizon won't process jobs."
        fi
        # Keep the queue's retry_after above Horizon's job timeout (see deploy_install_horizon,
        # HORIZON_TIMEOUT default 300). If retry_after <= timeout, a job that legitimately runs
        # longer than retry_after is released and re-reserved while still running (double
        # processing). Idempotent: only sets it when the operator hasn't set one explicitly.
        local _ra; _ra="$(env_get_key "$app_root" REDIS_QUEUE_RETRY_AFTER 2>/dev/null | tr -d '[:space:]')"
        if [[ -z "$_ra" ]]; then
          local _ht; _ht="$(env_get_key "$app_root" HORIZON_TIMEOUT 2>/dev/null | tr -d '[:space:]')"
          [[ "$_ht" =~ ^[0-9]+$ ]] || _ht=300
          step "Setting REDIS_QUEUE_RETRY_AFTER=$((_ht + 30)) (must exceed Horizon timeout)" \
            env_set_key "$app_root" REDIS_QUEUE_RETRY_AFTER "$((_ht + 30))" \
            || warn "Could not set REDIS_QUEUE_RETRY_AFTER — set it above HORIZON_TIMEOUT manually."
        fi
        # Size Horizon's pool to the server (once); the operator can change it
        # later with `server worker <site> scale`.
        if [[ -z "$SITE_WORKER_PROCS" ]]; then
          local rec; rec="$(_autowire_rec "$app_root")"
          if [[ -n "$rec" ]]; then
            env_set_key "$app_root" HORIZON_MAX_PROCESSES "$rec" >/dev/null 2>&1 || true
            SITE_WORKER_PROCS="$rec"; remote_site_set_kv "$domain" worker_procs "$rec" || true
            ok "Horizon pool sized to ${rec} (recommended for this server)."
          fi
        fi
      elif [[ -z "$SITE_QUEUE" ]]; then
        SITE_QUEUE=1; remote_site_set_kv "$domain" queue 1 || true
        _autowire_default_procs "$domain" "$app_root"
      fi
    fi
  elif [[ "$fw" == symfony ]]; then
    if [[ -z "$SITE_QUEUE" ]]; then
      local kind; kind="$(deploy_detect_worker "$app_root" "$fw")"
      if [[ "$kind" == messenger ]]; then
        SITE_QUEUE=1; remote_site_set_kv "$domain" queue 1 || true
        ok "Messenger consumer worker enabled."
        _autowire_default_procs "$domain" "$app_root"
      fi
    fi
  fi
}

# _autowire_rec <app_root> — echo the recommended worker count (empty on failure).
_autowire_rec() {
  local rec; rec="$(workers_recommend_procs 2>/dev/null)"; rec="${rec%% *}"
  [[ "$rec" =~ ^[0-9]+$ ]] && printf '%s' "$rec"
}

# _autowire_default_procs <domain> <app_root> — set worker_procs to the
# recommendation when the operator hasn't picked one (supervisor numprocs).
_autowire_default_procs() {
  local domain="$1" app_root="$2"
  [[ -n "$SITE_WORKER_PROCS" ]] && return 0
  local rec; rec="$(_autowire_rec "$app_root")"
  [[ -n "$rec" ]] || return 0
  SITE_WORKER_PROCS="$rec"; remote_site_set_kv "$domain" worker_procs "$rec" || true
  ok "Worker pool sized to ${rec} processes (recommended for this server)."
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

# _deploy_try <step-label> <diagnoser> -- <run-cmd...>
#   Run a deploy step; if it fails, hand the captured output to <diagnoser>,
#   which inspects the error, performs a TARGETED remediation (its own visible
#   "Auto-fix" step) and returns 0 to request a retry — or non-zero to give up.
#   The step is retried at most once. This is what lets a deploy recover on its
#   own from "composer not found", a missing PHP extension, a missing Node /
#   package manager, etc.
#
#   The timeline reads: step ✖  →  Auto-fix ✔  →  step (retry) ✔.
#   Returns the final step's status.
_deploy_try() {
  local label="$1" diagnoser="$2"; shift 2
  local run=() seen=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen=1; continue; fi
    (( seen )) && run+=("$a")
  done

  local log; log="$(mktemp "${TMPDIR:-/tmp}/srvmgr-diag.XXXXXX")"
  _UI_STEP_LOGOUT="$log"
  step "$label" "${run[@]}"; local rc=$?
  _UI_STEP_LOGOUT=""

  if (( rc == 0 )); then rm -f "$log"; return 0; fi

  warn "${label} failed — diagnosing the error…"
  if "$diagnoser" "$log"; then
    rm -f "$log"
    step "${label} (retry)" "${run[@]}"
    return $?
  fi
  rm -f "$log"
  return 1   # no remediation matched → let the caller abort
}

# _diagnose_composer <logfile> — pick a targeted fix for a failed composer step.
# Reads the captured output and matches known failure signatures. Returns 0
# (after running an Auto-fix step) to request a retry, non-zero to abort.
_diagnose_composer() {
  local out; out="$(cat "$1" 2>/dev/null)"

  # Missing PHP extension: "requires ... ext-gd ...", "the requested PHP
  # extension intl is missing", "ext-bcmath * -> it is missing".
  local ext=""
  ext="$(printf '%s\n' "$out" | grep -oiE 'ext-[a-z0-9_]+' | head -1 | sed 's/^ext-//I')"
  [[ -z "$ext" ]] && ext="$(printf '%s\n' "$out" | grep -oiE 'PHP extension [a-z0-9_]+' | head -1 | awk '{print $3}')"
  if [[ -n "$ext" ]]; then
    step "Auto-fix: installing PHP extension ${ext}" toolchain_ensure_php_ext "$_UPD_PHP" "$ext"
    return $?
  fi

  # Missing unzip / zip for prefer-dist.
  if printf '%s' "$out" | grep -qiE 'unzip|zip extension|install (it|unzip)'; then
    step "Auto-fix: installing unzip" toolchain_ensure_unzip; return $?
  fi

  # git needed by composer to clone a source dependency.
  if printf '%s' "$out" | grep -qiE 'git was not found|git: (command )?not found'; then
    step "Auto-fix: installing git" toolchain_ensure_git; return $?
  fi

  # composer itself missing.
  if printf '%s' "$out" | grep -qiE 'composer:? (command )?not found|composer not found'; then
    step "Auto-fix: installing Composer" toolchain_ensure_composer; return $?
  fi

  # Fallback: ensure the composer toolchain (covers most missing-tool cases).
  step "Auto-fix: ensuring Composer toolchain" toolchain_ensure_composer
}

# _diagnose_node <logfile> — pick a targeted fix for a failed frontend build.
_diagnose_node() {
  local out; out="$(cat "$1" 2>/dev/null)"
  # Prefer the package manager deploy_node actually used (it reports it in the
  # "package manager '<pm>' not found" message after auto-detecting from the
  # lockfile); fall back to the configured one, then npm.
  local pm; pm="$(printf '%s' "$out" | sed -n "s/.*package manager '\([^']*\)'.*/\1/p" | head -1)"
  [[ -n "$pm" ]] || pm="${SITE_NODE_PM:-npm}"

  # Out of disk — not something we can auto-fix.
  if printf '%s' "$out" | grep -qiE 'ENOSPC|no space left'; then
    err "Build failed: the server is out of disk space. Cannot auto-fix."
    return 1
  fi

  # node / package manager missing.
  if printf '%s' "$out" | grep -qiE "not found|command not found|No such file|ENOENT.*${pm}"; then
    step "Auto-fix: installing Node.js + ${pm}" toolchain_ensure_pm "$pm"; return $?
  fi

  # Fallback: ensure the package manager (and Node) are present.
  step "Auto-fix: ensuring ${pm}" toolchain_ensure_pm "$pm"
}

# _update_all [--framework <fw>] — deploy every registered site (optionally
# filtered by --server / --framework), continuing past individual failures.
_update_all() {
  shift || true   # drop "--all"
  local fw_filter=""
  while (( $# )); do
    case "$1" in
      --framework) fw_filter="${2:-}"; shift 2;;
      *) shift;;
    esac
  done

  local entries; entries="$(index_all)"
  [[ -n "${entries//[$'\n'[:space:]]/}" ]] || die "No sites registered. Add one with 'server add'."

  local targets=() domain srv
  while IFS=$'\t' read -r domain srv || [[ -n "$domain" ]]; do
    [[ -z "$domain" ]] && continue
    [[ -n "$OPT_SERVER" && "$srv" != "$OPT_SERVER" ]] && continue
    if [[ -n "$fw_filter" ]]; then
      registry_exists "$srv" || continue
      ssh_use_server "$srv"
      site_load "$domain" 2>/dev/null || continue
      if [[ "$fw_filter" == laravel ]]; then
        _is_laravel_like "$SITE_FRAMEWORK" || continue
      else
        [[ "$SITE_FRAMEWORK" == "$fw_filter" ]] || continue
      fi
    fi
    targets+=("$domain")
  done <<<"$entries"

  banner "update --all — ${#targets[@]} site(s)${fw_filter:+ (${fw_filter})}"
  if (( ${#targets[@]} == 0 )); then
    warn "No sites matched."; return 0
  fi

  local ok_c=0 fail_c=0 d
  for d in "${targets[@]}"; do
    section "▶ ${d}"
    if ( cmd_update "$d" ); then ok_c=$((ok_c+1)); else fail_c=$((fail_c+1)); warn "${d}: deploy failed (continuing)."; fi
  done

  ok "Done: ${ok_c} deployed, ${fail_c} failed (of ${#targets[@]})."
  if json_mode; then ui_emit "{\"t\":\"data\",$(json_kv_string kind deploy_all),$(json_kv_raw value "{$(json_kv_raw total "${#targets[@]}"),$(json_kv_raw deployed "$ok_c"),$(json_kv_raw failed "$fail_c")}")}"; fi
  return 0
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
  notify_send failure "Deploy failed: ${domain}" "${msg}" || true
  err "Deploy aborted. A backup was saved at ${backup} — use 'server rollback ${domain}' if needed."
  exit 1
}
