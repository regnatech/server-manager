# shellcheck shell=bash
#
# discover.sh — assembles the per-aspect snippets into a single remote payload,
# runs it over one SSH round-trip, and parses the `key=value` output into
# DISC_* globals consumed by the `add`/`import` wizard.
#
# Requires a server already selected via ssh_use_server.

# The DISC_* result globals (reset on each run).
discover_reset() {
  DISC_APP_ROOT="" DISC_FRAMEWORK="" DISC_PHP_VERSION="" DISC_PHP_SOCKET=""
  DISC_GIT_REMOTE="" DISC_GIT_BRANCH="" DISC_GIT_COMMIT="" DISC_NODE_PM=""
  DISC_APP_NAME="" DISC_QUEUE="" DISC_REDIS="" DISC_HORIZON="" DISC_OCTANE=""
  DISC_SCHEDULER="" DISC_HAS_COMPOSER="" DISC_HAS_PACKAGE=""
}

# discover_collect <root> — run the remote inspection and echo the raw
# `key=value` lines to stdout (no globals touched, so it is safe to call from a
# subshell / command substitution / spinner).
discover_collect() {
  local root="$1"

  local payload
  payload="$(cat <<EOF
set -u
ROOT=$(shq "$root")

# Locate the application root (where composer.json/package.json/.git live).
APP_ROOT="\$ROOT"
for cand in "\$ROOT" "\$(dirname "\$ROOT")"; do
  if [ -e "\$cand/composer.json" ] || [ -e "\$cand/package.json" ] \\
     || [ -e "\$cand/artisan" ] || [ -d "\$cand/.git" ]; then
    APP_ROOT="\$cand"; break
  fi
done
echo "app_root=\$APP_ROOT"

$(_disc_framework_snippet)
$(_disc_git_snippet)
$(_disc_node_snippet)
$(_disc_php_snippet)
EOF
)"

  printf '%s\n' "$payload" | ssh_script
}

# discover_parse — read `key=value` lines from stdin and set the DISC_* globals.
discover_parse() {
  discover_reset
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      app_root)     DISC_APP_ROOT="$val";;
      framework)    DISC_FRAMEWORK="$val";;
      php_version)  DISC_PHP_VERSION="$val";;
      php_socket)   DISC_PHP_SOCKET="$val";;
      git_remote)   DISC_GIT_REMOTE="$val";;
      git_branch)   DISC_GIT_BRANCH="$val";;
      git_commit)   DISC_GIT_COMMIT="$val";;
      node_pm)      DISC_NODE_PM="$val";;
      app_name)     DISC_APP_NAME="$val";;
      queue)        DISC_QUEUE="$val";;
      redis)        DISC_REDIS="$val";;
      horizon)      DISC_HORIZON="$val";;
      octane)       DISC_OCTANE="$val";;
      scheduler)    DISC_SCHEDULER="$val";;
      has_composer) DISC_HAS_COMPOSER="$val";;
      has_package)  DISC_HAS_PACKAGE="$val";;
    esac
  done
}

# Pretty label for a framework key.
framework_label() {
  case "$1" in
    laravel) echo "Laravel";;       symfony) echo "Symfony";;
    wordpress) echo "WordPress";;   statamic) echo "Statamic";;
    static) echo "Static Website";; nodejs) echo "Node.js";;
    react) echo "React";;           vue) echo "Vue";;
    nuxt) echo "Nuxt";;             nextjs) echo "Next.js";;
    reverse_proxy) echo "Reverse Proxy";;
    *) echo "${1:-unknown}";;
  esac
}

# is_php_framework <fw> — true for frameworks that use PHP-FPM.
is_php_framework() {
  case "$1" in laravel|symfony|wordpress|statamic) return 0;; *) return 1;; esac
}

# is_node_framework <fw>
is_node_framework() {
  case "$1" in nodejs|nuxt|nextjs) return 0;; *) return 1;; esac
}
