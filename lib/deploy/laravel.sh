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
