# shellcheck shell=bash
#
# healthcheck.sh — post-deploy verification. Emits one `name|status|detail`
# line per relevant check to stdout; the caller renders ✔/✖. Returns non-zero
# if a critical check (nginx or HTTP) fails.
#
# Only the checks that apply to the site are run (php-fpm for PHP sites,
# supervisor when there are workers, redis when configured).

# deploy_healthcheck <domain> <https> <want_php> <want_supervisor> <want_redis>
deploy_healthcheck() {
  local domain="$1" https="$2" want_php="$3" want_sup="$4" want_redis="$5"
  ssh_script <<EOF
domain=$(shq "$domain")
https=$(shq "$https")
want_php=$(shq "$want_php")
want_sup=$(shq "$want_sup")
want_redis=$(shq "$want_redis")
crit_fail=0

is_active() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active "\$1" >/dev/null 2>&1 && return 0
  fi
  pgrep -x "\$1" >/dev/null 2>&1 || pgrep -f "\$1" >/dev/null 2>&1
}

# nginx (critical)
if is_active nginx; then echo "nginx|ok|running"
else echo "nginx|fail|not running"; crit_fail=1; fi

# php-fpm
if [ "\$want_php" = 1 ]; then
  if pgrep -f php-fpm >/dev/null 2>&1; then echo "php-fpm|ok|running"
  else echo "php-fpm|fail|not running"; fi
fi

# supervisor
if [ "\$want_sup" = 1 ]; then
  if is_active supervisor || is_active supervisord; then echo "supervisor|ok|running"
  else echo "supervisor|warn|not running"; fi
fi

# redis
if [ "\$want_redis" = 1 ]; then
  if command -v redis-cli >/dev/null 2>&1 && [ "\$(redis-cli ping 2>/dev/null)" = "PONG" ]; then
    echo "redis|ok|PONG"
  else echo "redis|warn|no PONG"; fi
fi

# HTTP (critical) — hit nginx locally with the right Host header (no external DNS needed)
code=000
if command -v curl >/dev/null 2>&1; then
  code="\$(curl -s -o /dev/null -w '%{http_code}' -H "Host: \$domain" --max-time 10 http://127.0.0.1/ 2>/dev/null || echo 000)"
fi
case "\$code" in
  2*|3*) echo "http|ok|\$code";;
  000)   echo "http|warn|no response (curl missing or refused)";;
  *)     echo "http|fail|\$code"; crit_fail=1;;
esac

exit \$crit_fail
EOF
}
