# shellcheck shell=bash
#
# symfony.sh (deploy) — Symfony console steps of the deploy. The remote PHP
# binary is resolved like the Laravel steps (php<version> with a fallback to
# `php`). Each helper is a no-op when bin/console (or the relevant component)
# isn't present.

# deploy_symfony_migrate <app_root> <php_version>
#   Run Doctrine migrations non-interactively. Skips cleanly when bin/console or
#   doctrine/migrations isn't installed; --allow-no-migration makes "nothing to
#   migrate" a success rather than an error.
deploy_symfony_migrate() {
  local app_root="$1" ver="$2"
  ssh_app_exec "$app_root" "
    $(_php_bin_prelude "$ver")
    [ -f bin/console ] || { echo 'no bin/console — skipping migrations'; exit 0; }
    if ! \$PHP bin/console list 2>/dev/null | grep -q 'doctrine:migrations'; then
      echo 'doctrine migrations not installed — skipping'; exit 0
    fi
    \$PHP bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration
  "
}

# deploy_symfony_cache <app_root> <php_version>
#   Clear + warm the cache for the configured APP_ENV (best-effort).
deploy_symfony_cache() {
  local app_root="$1" ver="$2"
  ssh_app_exec "$app_root" "
    $(_php_bin_prelude "$ver")
    [ -f bin/console ] || exit 0
    \$PHP bin/console cache:clear && { \$PHP bin/console cache:warmup || true; }
  "
}
