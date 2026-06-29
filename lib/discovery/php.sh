# shellcheck shell=bash
#
# php.sh — remote snippet detecting the required/installed PHP version and the
# matching php-fpm unix socket. Also surfaces Laravel/Statamic specifics read
# from composer.json and .env.

_disc_php_snippet() {
cat <<'SNIPPET'
# --- php version + fpm socket ------------------------------------------
phpver=""
if [ -f "$APP_ROOT/composer.json" ]; then
  phpver=$(grep -oE '"php"[[:space:]]*:[[:space:]]*"[^"]*"' "$APP_ROOT/composer.json" \
           | grep -oE '[0-9]+\.[0-9]+' | head -1)
fi
if [ -z "$phpver" ] && command -v php >/dev/null 2>&1; then
  phpver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
fi
[ -n "$phpver" ] && echo "php_version=$phpver"

sock=""
if [ -n "$phpver" ] && [ -S "/run/php/php${phpver}-fpm.sock" ]; then
  sock="/run/php/php${phpver}-fpm.sock"
else
  for s in /run/php/php*-fpm.sock /run/php-fpm/*.sock /var/run/php-fpm/*.sock; do
    [ -S "$s" ] && { sock="$s"; break; }
  done
fi
[ -n "$sock" ] && echo "php_socket=$sock"

# --- Laravel / Statamic specifics --------------------------------------
if [ "$fw" = laravel ] || [ "$fw" = statamic ]; then
  envf="$APP_ROOT/.env"
  if [ -f "$envf" ]; then
    an=$(grep -E '^APP_NAME=' "$envf" | head -1 | cut -d= -f2- | tr -d '"'"'"'')
    [ -n "$an" ] && echo "app_name=$an"
    qc=$(grep -E '^QUEUE_CONNECTION=' "$envf" | head -1 | cut -d= -f2- | tr -d '"'"'"'' | tr -d '[:space:]')
    [ -n "$qc" ] && [ "$qc" != "sync" ] && echo "queue=1"
    grep -qE '^REDIS_HOST=' "$envf" && echo "redis=1"
  fi
  grep -q 'laravel/horizon' "$APP_ROOT/composer.json" 2>/dev/null && echo "horizon=1"
  grep -q 'laravel/octane'  "$APP_ROOT/composer.json" 2>/dev/null && echo "octane=1"
  echo "scheduler=1"
fi
SNIPPET
}
