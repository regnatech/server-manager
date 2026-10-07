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

# deploy_composer <app_root> — install if composer.json is present.
deploy_composer() {
  local app_root="$1" auth env=""
  auth="$(_deploy_composer_auth)"
  [[ -n "$auth" ]] && env="export COMPOSER_AUTH=$(shq "$auth")
"
  ssh_app_exec "$app_root" "$env"'
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
