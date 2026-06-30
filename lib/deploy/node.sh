# shellcheck shell=bash
#
# node.sh (deploy) — install JS deps and run the production build. The package
# manager is taken from the site config when known, otherwise auto-detected from
# the lockfile at deploy time (bun/pnpm/yarn/npm). Only runs the build when
# package.json declares a "build" script; a no-op when there's no package.json.

# deploy_node <app_root> [pm]
deploy_node() {
  local app_root="$1" pm="${2:-}"
  ssh_app_exec "$app_root" "
    if [ ! -f package.json ]; then echo 'no package.json — skipping'; exit 0; fi
    pm=$(shq "$pm")
    if [ -z \"\$pm\" ]; then
      # Auto-detect from the lockfile (matches lib/discovery/node.sh).
      if   [ -f bun.lockb ] || [ -f bun.lock ]; then pm=bun
      elif [ -f pnpm-lock.yaml ];               then pm=pnpm
      elif [ -f yarn.lock ];                    then pm=yarn
      else                                           pm=npm
      fi
    fi
    if ! command -v \"\$pm\" >/dev/null 2>&1; then
      echo \"package manager '\$pm' not found on PATH\" >&2; exit 1
    fi
    case \"\$pm\" in
      bun)  bun install ;;
      pnpm) pnpm install --frozen-lockfile || pnpm install ;;
      yarn) yarn install --frozen-lockfile || yarn install ;;
      npm)  npm ci || npm install ;;
    esac
    # Run build only if the script exists.
    if grep -q '\"build\"[[:space:]]*:' package.json; then
      case \"\$pm\" in
        bun)  bun run build ;;
        pnpm) pnpm run build ;;
        yarn) yarn build ;;
        npm)  npm run build ;;
      esac
    else
      echo 'no build script — skipping build'
    fi
  "
}
