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

# deploy_git_pull <app_root> <branch> — fast-forward pull from origin.
deploy_git_pull() {
  local app_root="$1" branch="$2"
  ssh_app_exec "$app_root" "git fetch --all --prune && git checkout $(shq "$branch") && git pull --ff-only origin $(shq "$branch")"
}

# deploy_git_reset <app_root> <target> — hard reset to a ref/sha (rollback).
deploy_git_reset() {
  local app_root="$1" target="$2"
  ssh_app_exec "$app_root" "git fetch --all --prune && git reset --hard $(shq "$target")"
}
