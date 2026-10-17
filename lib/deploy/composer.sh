# shellcheck shell=bash
#
# composer.sh — PHP dependency install for production deploys.

# _deploy_composer_auth — echo the COMPOSER_AUTH JSON built from the configured
# github_token, or nothing when no usable token is set. With it composer can
# download private GitHub packages: --prefer-dist fetches them as zip archives
# through the GitHub API, which answers 404 to anonymous requests for a private
# repository. Like the git fetch in git.sh, the token lives only in the
# environment of that one remote command: it is never written to auth.json,
# composer.json or the app tree.
_deploy_composer_auth() {
  local tok
  tok="$(global_get github_token 2>/dev/null || true)"
  [[ -n "$tok" ]] || return 0
  # GitHub tokens are [A-Za-z0-9_]; anything else would break the JSON (or worse).
  if [[ ! "$tok" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "warn: github_token has unexpected characters — not passed to composer" >&2
    return 0
  fi
  printf '{"github-oauth":{"github.com":"%s"}}' "$tok"
}

# deploy_composer <app_root> [php_version] — install if composer.json is present.
# Composer runs on the site's PHP (php8.4 …), not on the server default: with two
# versions installed, `composer` alone checks the platform against whatever
# /usr/bin/php points to, and a lock that needs 8.4 fails on a host whose
# default is still 8.3.
deploy_composer() {
  local app_root="$1" ver="${2:-}" auth env="" php_prelude=""
  [[ -n "$ver" ]] && php_prelude="$(_php_bin_prelude "$ver")"
  auth="$(_deploy_composer_auth)"
  [[ -n "$auth" ]] && env="export COMPOSER_AUTH=$(shq "$auth")
"
  ssh_app_exec "$app_root" "$env"'
    if [ ! -f composer.json ]; then echo "no composer.json — skipping"; exit 0; fi
    '"$php_prelude"'
    if [ -n "${PHP:-}" ] && command -v composer >/dev/null 2>&1; then COMPOSER="$PHP $(command -v composer)";
    elif command -v composer >/dev/null 2>&1; then COMPOSER=composer;
    elif [ -f composer.phar ]; then COMPOSER="${PHP:-php} composer.phar";
    else echo "composer not found on PATH" >&2; exit 1; fi
    # -1 disables the memory limit: large dependency graphs otherwise OOM with
    # "Allowed memory size ... exhausted". Cheap to set unconditionally.
    export COMPOSER_MEMORY_LIMIT=-1
    $COMPOSER install --no-dev --prefer-dist --optimize-autoloader --no-interaction
  '
}
