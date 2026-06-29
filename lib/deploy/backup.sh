# shellcheck shell=bash
#
# backup.sh — capture a restore point before a deploy: the nginx vhost, the
# app's .env, and (for Laravel/Statamic with a MySQL/Postgres connection) a
# compressed database dump. Everything lands under
# /var/backups/server-manager/<domain>/<timestamp>/.
#
# Requires a server selected via ssh_use_server.

# deploy_backup <domain> <app_root> <framework> <backup_dir>
deploy_backup() {
  local domain="$1" app_root="$2" fw="$3" backup_dir="$4"
  ssh_script --sudo <<EOF
set -e
domain=$(shq "$domain")
app_root=$(shq "$app_root")
fw=$(shq "$fw")
bdir=$(shq "$backup_dir")

mkdir -p "\$bdir"

# nginx vhost
for f in "/etc/nginx/sites-available/\$domain" "/etc/nginx/conf.d/\$domain.conf"; do
  [ -f "\$f" ] && cp "\$f" "\$bdir/nginx.conf"
done

# .env
[ -f "\$app_root/.env" ] && cp "\$app_root/.env" "\$bdir/.env"

# database (Laravel / Statamic only)
if [ "\$fw" = laravel ] || [ "\$fw" = statamic ]; then
  envf="\$app_root/.env"
  if [ -f "\$envf" ]; then
    get() { grep -E "^\$1=" "\$envf" | head -1 | cut -d= -f2- | tr -d '"'"'"'' | tr -d '[:space:]'; }
    conn="\$(get DB_CONNECTION)"; dbh="\$(get DB_HOST)"; dbp="\$(get DB_PORT)"
    dbn="\$(get DB_DATABASE)"; dbu="\$(get DB_USERNAME)"; dbpw="\$(get DB_PASSWORD)"
    case "\$conn" in
      mysql|mariadb)
        if command -v mysqldump >/dev/null 2>&1 && [ -n "\$dbn" ]; then
          MYSQL_PWD="\$dbpw" mysqldump --single-transaction --quick --no-tablespaces \
            -h "\${dbh:-127.0.0.1}" -P "\${dbp:-3306}" -u "\$dbu" "\$dbn" \
            | gzip > "\$bdir/db.sql.gz" || echo "warn: mysqldump failed" >&2
        fi;;
      pgsql|postgres|postgresql)
        if command -v pg_dump >/dev/null 2>&1 && [ -n "\$dbn" ]; then
          PGPASSWORD="\$dbpw" pg_dump -h "\${dbh:-127.0.0.1}" -p "\${dbp:-5432}" \
            -U "\$dbu" "\$dbn" | gzip > "\$bdir/db.sql.gz" || echo "warn: pg_dump failed" >&2
        fi;;
    esac
  fi
fi
echo "backup stored in \$bdir"
EOF
}

# deploy_restore_db <app_root> <framework> <backup_dir> — restore db.sql.gz if
# present (used by rollback).
deploy_restore_db() {
  local app_root="$1" fw="$2" backup_dir="$3"
  ssh_script --sudo <<EOF
set -e
app_root=$(shq "$app_root")
fw=$(shq "$fw")
bdir=$(shq "$backup_dir")
dump="\$bdir/db.sql.gz"
[ -f "\$dump" ] || { echo "no database dump in \$bdir — skipping db restore"; exit 0; }
[ "\$fw" = laravel ] || [ "\$fw" = statamic ] || { echo "not a db framework — skipping"; exit 0; }

envf="\$app_root/.env"
get() { grep -E "^\$1=" "\$envf" | head -1 | cut -d= -f2- | tr -d '"'"'"'' | tr -d '[:space:]'; }
conn="\$(get DB_CONNECTION)"; dbh="\$(get DB_HOST)"; dbp="\$(get DB_PORT)"
dbn="\$(get DB_DATABASE)"; dbu="\$(get DB_USERNAME)"; dbpw="\$(get DB_PASSWORD)"
case "\$conn" in
  mysql|mariadb)
    MYSQL_PWD="\$dbpw" sh -c "gzip -dc '\$dump' | mysql -h '\${dbh:-127.0.0.1}' -P '\${dbp:-3306}' -u '\$dbu' '\$dbn'";;
  pgsql|postgres|postgresql)
    PGPASSWORD="\$dbpw" sh -c "gzip -dc '\$dump' | psql -h '\${dbh:-127.0.0.1}' -p '\${dbp:-5432}' -U '\$dbu' '\$dbn'";;
  *) echo "unknown DB connection '\$conn' — skipping";;
esac
echo "database restored from \$dump"
EOF
}

# deploy_restore_env <app_root> <backup_dir> — put back the saved .env.
deploy_restore_env() {
  local app_root="$1" backup_dir="$2"
  ssh_sudo "test -f $(shq "$backup_dir/.env") && cp $(shq "$backup_dir/.env") $(shq "$app_root/.env") && echo '.env restored' || echo 'no .env backup to restore'"
}
