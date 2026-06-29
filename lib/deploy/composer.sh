# shellcheck shell=bash
#
# composer.sh — PHP dependency install for production deploys.

# deploy_composer <app_root> — install if composer.json is present.
deploy_composer() {
  local app_root="$1"
  ssh_app_exec "$app_root" '
    if [ ! -f composer.json ]; then echo "no composer.json — skipping"; exit 0; fi
    if command -v composer >/dev/null 2>&1; then COMPOSER=composer;
    elif [ -f composer.phar ]; then COMPOSER="php composer.phar";
    else echo "composer not found on PATH" >&2; exit 1; fi
    # -1 disables the memory limit: large dependency graphs otherwise OOM with
    # "Allowed memory size ... exhausted". Cheap to set unconditionally.
    export COMPOSER_MEMORY_LIMIT=-1
    $COMPOSER install --no-dev --prefer-dist --optimize-autoloader --no-interaction
  '
}
