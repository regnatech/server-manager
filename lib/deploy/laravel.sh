# shellcheck shell=bash
#
# laravel.sh — artisan-driven steps of the deploy. The remote PHP binary is
# resolved from the site's configured version (php8.3) with a fallback to the
# default `php`. A guard makes every helper a no-op for non-Laravel sites.

# Remote prelude that sets $PHP. Interpolated into command strings; expects the
# site PHP version as the single argument captured into $1 on the remote.
_php_bin_prelude() {
  local ver="$1"
  printf 'PHP=php; if command -v php%s >/dev/null 2>&1; then PHP=php%s; fi; ' "$ver" "$ver"
}

# is_laravel_like <framework>
_is_laravel_like() { [[ "$1" == "laravel" || "$1" == "statamic" ]]; }

# deploy_laravel_down <app_root> <php_version>
deploy_laravel_down() {
  local app_root="$1" ver="$2"
  ssh_app_exec "$app_root" "$(_php_bin_prelude "$ver") \$PHP artisan down --render='errors::503' --retry=15 || true"
}

# deploy_laravel_up <app_root> <php_version>
deploy_laravel_up() {
  local app_root="$1" ver="$2"
  ssh_app_exec "$app_root" "$(_php_bin_prelude "$ver") \$PHP artisan up || true"
}

# deploy_laravel_migrate <app_root> <php_version>
deploy_laravel_migrate() {
  local app_root="$1" ver="$2"
  ssh_app_exec "$app_root" "$(_php_bin_prelude "$ver") \$PHP artisan migrate --force"
}

# deploy_laravel_optimize <app_root> <php_version>
#   Clear then rebuild all caches (config/route/view/event).
deploy_laravel_optimize() {
  local app_root="$1" ver="$2"
  ssh_app_exec "$app_root" "$(_php_bin_prelude "$ver") \
    \$PHP artisan optimize:clear && \
    \$PHP artisan optimize && \
    \$PHP artisan config:cache && \
    \$PHP artisan route:cache && \
    \$PHP artisan view:cache && \
    { \$PHP artisan event:cache || true; }"
}

# deploy_detect_worker <app_root> <framework> — decide which background worker a
# site needs, printed on stdout: horizon | queue | messenger | none.
#   * Laravel/Statamic: horizon if laravel/horizon is required; else queue when
#     QUEUE_CONNECTION is set to something other than 'sync'; else none.
#   * Symfony: messenger when symfony/messenger is required; else none.
deploy_detect_worker() {
  local app_root="$1" fw="$2"
  ssh_app_exec "$app_root" "
    [ -f composer.json ] || { echo none; exit 0; }
    case $(shq "$fw") in
      laravel|statamic)
        if grep -q '\"laravel/horizon\"' composer.json 2>/dev/null; then echo horizon; exit 0; fi
        qc=\$(grep -E '^QUEUE_CONNECTION=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\"' | tr -d '[:space:]')
        if [ -n \"\$qc\" ] && [ \"\$qc\" != sync ]; then echo queue; else echo none; fi ;;
      symfony)
        if grep -q '\"symfony/messenger\"' composer.json 2>/dev/null; then echo messenger; else echo none; fi ;;
      *) echo none ;;
    esac
  "
}

# deploy_horizon_present <app_root> — 0 if laravel/horizon is installed in vendor.
deploy_horizon_present() {
  ssh_app_exec "$1" "test -d vendor/laravel/horizon"
}

# deploy_install_horizon <app_root> <php_version> — composer require laravel/horizon
# and run horizon:install, if Horizon isn't already in vendor. Because deploys
# reset the working tree to the repo tip, this re-runs each deploy until the
# project commits laravel/horizon to its own composer.json.
deploy_install_horizon() {
  local app_root="$1" ver="$2"
  ssh_app_exec "$app_root" "
    $(_php_bin_prelude "$ver")
    if [ -d vendor/laravel/horizon ]; then echo 'horizon already installed'; exit 0; fi
    export COMPOSER_MEMORY_LIMIT=-1
    composer require laravel/horizon --no-interaction --no-progress || exit 1
    \$PHP artisan horizon:install --no-interaction || true
    # Make the worker pool size controllable from the .env so 'server worker
    # <site> scale' can drive it without editing the repo's config by hand.
    if [ -f config/horizon.php ] && ! grep -q HORIZON_MAX_PROCESSES config/horizon.php; then
      sed -i -E \"s/('maxProcesses'[[:space:]]*=>[[:space:]]*)([0-9]+)/\\1(int) env('HORIZON_MAX_PROCESSES', \\2)/g\" config/horizon.php || true
    fi
    # Raise the supervisor job timeout from Horizon's stock 60s and make it env-driven.
    # 60s kills long jobs (e.g. LLM/API calls) mid-run BEFORE their own HTTP timeout can
    # throw a catchable exception, which leaves app-level records orphaned in 'processing'.
    # Default 300s > any sane per-request HTTP timeout; keep the connection retry_after above it.
    if [ -f config/horizon.php ] && ! grep -q HORIZON_TIMEOUT config/horizon.php; then
      sed -i -E \"s/('timeout'[[:space:]]*=>[[:space:]]*)([0-9]+)/\\1(int) env('HORIZON_TIMEOUT', 300)/g\" config/horizon.php || true
    fi
    echo 'horizon installed'
  "
}
