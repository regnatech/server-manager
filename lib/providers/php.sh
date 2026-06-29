# shellcheck shell=bash
#
# php.sh (provider) — install and locate PHP-FPM at a specific version on the
# managed server. Distinct from lib/discovery/php.sh, which only inspects.
#
# Requires a server selected via ssh_use_server.

# php_socket_for <version> -> the php-fpm unix socket for that version, if any.
# Trailing ': ' guarantees exit 0 even when nothing matches, so a bare
# assignment at the call site doesn't trip `set -e`.
php_socket_for() {
  local ver="$1"
  ssh_exec "for s in /run/php/php${ver}-fpm.sock /run/php-fpm/php${ver}.sock /var/run/php/php${ver}-fpm.sock; do [ -S \"\$s\" ] && { echo \"\$s\"; break; }; done; :"
}

# php_install <version>
#   Install PHP-FPM <version> plus the extensions a typical Laravel app needs.
#   Debian/Ubuntu: uses the ondrej/php PPA when the version isn't in the base
#   repos. RHEL-family: best-effort (default php-fpm). Composer is installed too
#   when missing, since deploys need it.
php_install() {
  local ver="$1"
  ssh_sudo "
    set -e
    ver=$(shq "$ver")
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y software-properties-common ca-certificates curl unzip
      if ! apt-cache show php\${ver}-fpm >/dev/null 2>&1; then
        add-apt-repository -y ppa:ondrej/php
        apt-get update -y
      fi
      apt-get install -y \
        php\${ver}-fpm php\${ver}-cli php\${ver}-common \
        php\${ver}-mysql php\${ver}-mbstring php\${ver}-xml php\${ver}-curl \
        php\${ver}-zip php\${ver}-bcmath php\${ver}-gd php\${ver}-intl \
        php\${ver}-sqlite3 php\${ver}-redis
      systemctl enable --now php\${ver}-fpm 2>/dev/null || service php\${ver}-fpm start || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y php-fpm php-cli php-mysqlnd php-mbstring php-xml php-gd php-bcmath php-intl php-pdo curl unzip || exit 1
      systemctl enable --now php-fpm || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y php-fpm php-cli php-mysqlnd php-mbstring php-xml php-gd php-bcmath php-intl php-pdo curl unzip || exit 1
      systemctl enable --now php-fpm || true
    else
      echo 'No supported package manager to install PHP automatically.' >&2; exit 1
    fi

    # Composer (deploys need it).
    if ! command -v composer >/dev/null 2>&1; then
      php -r \"copy('https://getcomposer.org/installer','/tmp/composer-setup.php');\" \
        && php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer \
        && rm -f /tmp/composer-setup.php || echo 'warn: composer install failed' >&2
    fi
    echo \"PHP \${ver} ready.\"
  "
}
