# shellcheck shell=bash
#
# node.sh (deploy) — install JS deps and run the production build using the
# package manager detected at `add` time (bun/pnpm/yarn/npm). Only runs the
# build when package.json declares a "build" script.

# deploy_node <app_root> <pm>
deploy_node() {
  local app_root="$1" pm="$2"
  ssh_app_exec "$app_root" "
    if [ ! -f package.json ]; then echo 'no package.json — skipping'; exit 0; fi
    pm=$(shq "$pm")
    [ -n \"\$pm\" ] || pm=npm
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
