# shellcheck shell=bash
#
# toolchain.sh — self-healing provisioning of the build tools a deploy needs.
#
# These helpers are the remediation half of the "try → fix → retry" deploy
# flow (see _deploy_try in lib/commands/update.sh). Each is:
#   * idempotent  — a no-op (exit 0) when the tool is already present, so it is
#                   safe to run speculatively before a retry;
#   * self-locating — works across Debian/Ubuntu (apt) and RHEL (dnf/yum);
#   * privileged   — installs system-wide, so they run via ssh_script --sudo.
#
# Requires a server selected via ssh_use_server.

# toolchain_ensure_composer — make sure `composer` is on PATH (install if not).
# Composer needs PHP to bootstrap; if PHP is missing we fail loudly rather than
# guessing a version (php_install handles that during `add`).
toolchain_ensure_composer() {
  ssh_script --sudo <<'EOF'
set -e
if command -v composer >/dev/null 2>&1; then
  echo "composer already present: $(composer --version 2>/dev/null | head -1)"
  exit 0
fi
# Composer unpacks dist zips — make sure unzip/git/curl are around too.
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y unzip git curl ca-certificates >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then dnf install -y unzip git curl >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then yum install -y unzip git curl >/dev/null 2>&1 || true
fi
if ! command -v php >/dev/null 2>&1; then
  echo "cannot install composer: php is not on PATH" >&2; exit 1
fi
php -r "copy('https://getcomposer.org/installer','/tmp/composer-setup.php');"
php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
rm -f /tmp/composer-setup.php
command -v composer >/dev/null 2>&1 || { echo "composer install failed" >&2; exit 1; }
echo "composer installed: $(composer --version 2>/dev/null | head -1)"
EOF
}

# toolchain_ensure_node — make sure Node.js (+ npm) are available (install LTS).
toolchain_ensure_node() {
  ssh_script --sudo <<'EOF'
set -e
if command -v node >/dev/null 2>&1; then
  echo "node already present: $(node --version)"
  exit 0
fi
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  # Prefer the NodeSource LTS repo; fall back to the distro packages.
  if curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1; then
    apt-get install -y nodejs
  else
    apt-get update -y
    apt-get install -y nodejs npm
  fi
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y nodejs npm
elif command -v yum >/dev/null 2>&1; then
  yum install -y nodejs npm
else
  echo "no supported package manager to install Node.js" >&2; exit 1
fi
command -v node >/dev/null 2>&1 || { echo "node install failed" >&2; exit 1; }
echo "node installed: $(node --version)"
EOF
}

# toolchain_ensure_pm <pm> — ensure the JS package manager <pm> is available.
# npm/pnpm/yarn require Node (installed first if missing); bun is standalone.
# pnpm/yarn are provisioned via corepack when available, else npm -g.
toolchain_ensure_pm() {
  local pm="$1"; [[ -n "$pm" ]] || pm=npm
  ssh_script --sudo <<EOF
set -e
pm=$(shq "$pm")

_install_node() {
  if command -v node >/dev/null 2>&1; then return 0; fi
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1 \
      && apt-get install -y nodejs \
      || { apt-get update -y; apt-get install -y nodejs npm; }
  elif command -v dnf >/dev/null 2>&1; then dnf install -y nodejs npm
  elif command -v yum >/dev/null 2>&1; then yum install -y nodejs npm
  fi
}

if command -v "\$pm" >/dev/null 2>&1; then
  echo "\$pm already present: \$(\$pm --version 2>/dev/null | head -1)"
  exit 0
fi

case "\$pm" in
  npm)
    _install_node
    command -v npm >/dev/null 2>&1 || { command -v apt-get >/dev/null 2>&1 && apt-get install -y npm; } ;;
  pnpm)
    _install_node
    corepack enable >/dev/null 2>&1 && corepack prepare pnpm@latest --activate >/dev/null 2>&1 \
      || npm install -g pnpm ;;
  yarn)
    _install_node
    corepack enable >/dev/null 2>&1 && corepack prepare yarn@stable --activate >/dev/null 2>&1 \
      || npm install -g yarn ;;
  bun)
    export BUN_INSTALL=/usr/local
    curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || true
    [ -x /usr/local/bin/bun ] || { [ -x "\$HOME/.bun/bin/bun" ] && install -m755 "\$HOME/.bun/bin/bun" /usr/local/bin/bun; } ;;
  *)
    echo "unknown package manager: \$pm" >&2; exit 1 ;;
esac

command -v "\$pm" >/dev/null 2>&1 || { echo "failed to provision \$pm" >&2; exit 1; }
echo "\$pm installed: \$(\$pm --version 2>/dev/null | head -1)"
EOF
}

# toolchain_ensure_git — make sure git is on PATH (install if missing).
toolchain_ensure_git() {
  ssh_script --sudo <<'EOF'
set -e
if command -v git >/dev/null 2>&1; then echo "git already present: $(git --version)"; exit 0; fi
if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y git
elif command -v dnf >/dev/null 2>&1; then dnf install -y git
elif command -v yum >/dev/null 2>&1; then yum install -y git
else echo "no supported package manager to install git" >&2; exit 1; fi
command -v git >/dev/null 2>&1 || { echo "git install failed" >&2; exit 1; }
echo "git installed: $(git --version)"
EOF
}
