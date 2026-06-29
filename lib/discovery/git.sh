# shellcheck shell=bash
#
# git.sh — remote snippet emitting origin remote, current branch and last
# commit for the application root (if it is a git working tree).

_disc_git_snippet() {
cat <<'SNIPPET'
# --- git ----------------------------------------------------------------
if [ -d "$APP_ROOT/.git" ] && command -v git >/dev/null 2>&1; then
  echo "git_remote=$(git -C "$APP_ROOT" remote get-url origin 2>/dev/null)"
  echo "git_branch=$(git -C "$APP_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "git_commit=$(git -C "$APP_ROOT" log -1 --format='%h %s' 2>/dev/null)"
fi
SNIPPET
}
