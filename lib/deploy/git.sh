# shellcheck shell=bash
#
# git.sh (deploy) — git operations used by update/rollback.

# deploy_git_sha <app_root> -> current HEAD sha (short). Empty if not a repo.
deploy_git_sha() {
  ssh_app_exec "$1" "git rev-parse --short HEAD 2>/dev/null || true"
}

# deploy_git_is_clean <app_root> — returns 0 if the working tree has no
# uncommitted changes.
deploy_git_is_clean() {
  local out
  out="$(ssh_app_exec "$1" "git status --porcelain 2>/dev/null")" || return 1
  [[ -z "$out" ]]
}

# deploy_git_valid <app_root> — returns 0 if it's a git repo with an origin.
deploy_git_valid() {
  ssh_app_exec "$1" "git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git remote get-url origin >/dev/null 2>&1"
}

# _deploy_git_auth_url <remote> — echo a fetch URL with embedded credentials
# when we can supply them (GitHub HTTPS + a configured github_token), otherwise
# the remote unchanged. The token is used only for the transfer; it is never
# written to the persisted 'origin' URL or to .git/config.
_deploy_git_auth_url() {
  local remote="$1" tok
  if [[ "$remote" == https://github.com/* ]]; then
    tok="$(global_get github_token 2>/dev/null || true)"
    [[ -n "$tok" ]] && {
      printf 'https://x-access-token:%s@%s' "$tok" "${remote#https://}"
      return
    }
  fi
  printf '%s' "$remote"
}

# deploy_git_clone <app_root> <remote> <branch> — bootstrap a first deploy by
# fetching <remote> into a fresh repo at <app_root>. Safe to run in a directory
# 'add' already created (e.g. holding a generated .env): existing untracked
# files are kept, and 'origin' is set to the clean, token-free URL.
deploy_git_clone() {
  local app_root="$1" remote="$2" branch="$3" auth
  auth="$(_deploy_git_auth_url "$remote")"
  ssh_app_exec "$app_root" "git init -q && { git remote get-url origin >/dev/null 2>&1 || git remote add origin $(shq "$remote"); } && git fetch --depth 1 $(shq "$auth") $(shq "$branch") && git checkout -f -B $(shq "$branch") FETCH_HEAD"
}

# deploy_git_pull <app_root> <branch> [remote] — update the checkout to the
# remote branch tip. A managed checkout is a deploy target, not a dev tree, so
# we hard-reset to the fetched commit: this discards any local changes (e.g. a
# deploy-time `composer require`) so the next deploy never trips on a dirty tree.
# When [remote] is a GitHub HTTPS URL and a token is configured, fetch through an
# authenticated URL (keeping the token out of config); otherwise use origin.
deploy_git_pull() {
  local app_root="$1" branch="$2" remote="${3:-}" auth=""
  [[ -n "$remote" ]] && auth="$(_deploy_git_auth_url "$remote")"
  if [[ -n "$auth" && "$auth" != "$remote" ]]; then
    ssh_app_exec "$app_root" "git fetch $(shq "$auth") $(shq "$branch") && git checkout -f -B $(shq "$branch") FETCH_HEAD"
  else
    ssh_app_exec "$app_root" "git fetch --all --prune && git checkout -f -B $(shq "$branch") origin/$(shq "$branch")"
  fi
}

# deploy_git_reset <app_root> <target> — hard reset to a ref/sha (rollback).
deploy_git_reset() {
  local app_root="$1" target="$2"
  ssh_app_exec "$app_root" "git fetch --all --prune && git reset --hard $(shq "$target")"
}
