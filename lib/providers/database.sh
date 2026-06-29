# shellcheck shell=bash
#
# database.sh — MariaDB provisioning for PHP (Laravel/Statamic) sites.
#
# Responsibilities:
#   * ensure mariadb-server is installed and running on the managed server;
#   * create a database + dedicated user with auto-generated credentials;
#   * write those credentials into the app's .env (creating one from a pasted
#     template when the project doesn't have one yet).
#
# The user never types a DB password — server-manager generates and reports it.
# Requires a server selected via ssh_use_server.

# db_gen_password — 24-char alnum password (no quoting hazards in SQL/.env).
# Reads a finite chunk of randomness and uses `cut` (which consumes all of its
# input) so no stage closes the pipe early — important under `set -o pipefail`,
# where a SIGPIPE'd `tr` reading /dev/urandom would otherwise abort the caller.
db_gen_password() {
  head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24
}

# db_is_present — returns 0 if a MariaDB/MySQL server is installed & reachable.
db_is_present() {
  ssh_exec 'command -v mysql >/dev/null 2>&1 && (command -v mysqld >/dev/null 2>&1 || command -v mariadbd >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -qE "^(mariadb|mysql)\.service")'
}

# db_install — install & start mariadb-server using the host's package manager.
db_install() {
  ssh_sudo '
    set -e
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y mariadb-server mariadb-client
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y mariadb-server
    elif command -v yum >/dev/null 2>&1; then
      yum install -y mariadb-server
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache mariadb mariadb-client
      command -v mariadb-install-db >/dev/null 2>&1 && mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1 || true
    elif command -v zypper >/dev/null 2>&1; then
      zypper install -y mariadb mariadb-client
    else
      echo "No supported package manager found to install MariaDB." >&2; exit 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysql 2>/dev/null || true
    else
      service mariadb start 2>/dev/null || service mysql start 2>/dev/null || rc-service mariadb start 2>/dev/null || true
    fi
    echo "MariaDB installed and started."
  '
}

# db_create <name> <user> <pass>
#   Create the database and user (root connects via unix_socket / sudo, the
#   default on a fresh MariaDB install). Idempotent.
db_create() {
  local name="$1" user="$2" pass="$3"
  ssh_script --sudo <<EOF
set -e
mysql <<'SQL'
CREATE DATABASE IF NOT EXISTS \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}';
CREATE USER IF NOT EXISTS '${user}'@'127.0.0.1' IDENTIFIED BY '${pass}';
ALTER USER '${user}'@'localhost' IDENTIFIED BY '${pass}';
ALTER USER '${user}'@'127.0.0.1' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON \`${name}\`.* TO '${user}'@'localhost';
GRANT ALL PRIVILEGES ON \`${name}\`.* TO '${user}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
echo "Database '${name}' and user '${user}' ready."
EOF
}

# db_env_exists <app_root>
db_env_exists() { ssh_exec "test -f $(shq "$1/.env")"; }

# db_write_env <app_root> < content — create the .env from pasted content.
db_write_env() {
  local app_root="$1"
  local body; body="$(cat)"
  ssh_script <<EOF
set -e
cat > $(shq "$app_root/.env") <<'SRVMGR_ENV_EOF'
${body}
SRVMGR_ENV_EOF
chmod 0640 $(shq "$app_root/.env")
echo ".env written."
EOF
}

# db_set_env_creds <app_root> <name> <user> <pass>
#   Set/replace the DB_* keys in the app's .env (in place), defaulting the
#   connection to mysql on 127.0.0.1:3306.
db_set_env_creds() {
  local app_root="$1" name="$2" user="$3" pass="$4"
  ssh_script <<EOF
set -e
envf=$(shq "$app_root/.env")
dbn=$(shq "$name"); dbu=$(shq "$user"); dbp=$(shq "$pass")
[ -f "\$envf" ] || { echo "no .env at \$envf" >&2; exit 1; }
tmp="\$(mktemp)"
awk -v dbn="\$dbn" -v dbu="\$dbu" -v dbp="\$dbp" '
  BEGIN{
    v["DB_CONNECTION"]="mysql"; o[++n]="DB_CONNECTION";
    v["DB_HOST"]="127.0.0.1";   o[++n]="DB_HOST";
    v["DB_PORT"]="3306";        o[++n]="DB_PORT";
    v["DB_DATABASE"]=dbn;       o[++n]="DB_DATABASE";
    v["DB_USERNAME"]=dbu;       o[++n]="DB_USERNAME";
    v["DB_PASSWORD"]=dbp;       o[++n]="DB_PASSWORD";
  }
  {
    matched=0
    for (i=1;i<=n;i++){ k=o[i]; if (k in v && \$0 ~ "^"k"="){ print k"="v[k]; delete v[k]; matched=1; break } }
    if (!matched) print \$0
  }
  END{ for (i=1;i<=n;i++){ k=o[i]; if (k in v) print k"="v[k] } }
' "\$envf" > "\$tmp"
cat "\$tmp" > "\$envf"
rm -f "\$tmp"
echo "DB credentials written to .env"
EOF
}
