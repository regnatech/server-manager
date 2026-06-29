# shellcheck shell=bash
#
# node.sh — remote snippet detecting the JS package manager from lock files.

_disc_node_snippet() {
cat <<'SNIPPET'
# --- node package manager ----------------------------------------------
if [ -f "$APP_ROOT/package.json" ]; then
  if   [ -f "$APP_ROOT/bun.lockb" ]      || [ -f "$APP_ROOT/bun.lock" ];   then echo "node_pm=bun"
  elif [ -f "$APP_ROOT/pnpm-lock.yaml" ];                                  then echo "node_pm=pnpm"
  elif [ -f "$APP_ROOT/yarn.lock" ];                                       then echo "node_pm=yarn"
  else                                                                          echo "node_pm=npm"
  fi
  echo "has_package=1"
fi
[ -f "$APP_ROOT/composer.json" ] && echo "has_composer=1"
SNIPPET
}
