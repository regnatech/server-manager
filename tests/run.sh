#!/usr/bin/env bash
#
# tests/run.sh — self-contained unit tests for server-manager.
#
# Pure-bash (no external test framework needed) so it runs out of the box,
# including on stock macOS bash 3.2. Covers the logic that can be exercised
# without a live server: discovery detection, nginx rendering, config/index
# round-trips, .env credential editing, validation helpers, and a syntax lint
# of every payload sent to remote hosts.
#
# Usage:  bash tests/run.sh        (exit 0 = all passed)

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVMGR_TEMPLATES="$ROOT/templates"

source "$ROOT/lib/core/ui.sh"
source "$ROOT/lib/core/util.sh"
source "$ROOT/lib/core/config.sh"
source "$ROOT/lib/discovery/framework.sh"
source "$ROOT/lib/discovery/git.sh"
source "$ROOT/lib/discovery/node.sh"
source "$ROOT/lib/discovery/php.sh"
source "$ROOT/lib/discovery/discover.sh"
source "$ROOT/lib/providers/nginx.sh"
source "$ROOT/lib/providers/database.sh"
source "$ROOT/lib/deploy/git.sh"
source "$ROOT/lib/deploy/composer.sh"
source "$ROOT/lib/deploy/node.sh"
source "$ROOT/lib/deploy/laravel.sh"
source "$ROOT/lib/deploy/services.sh"
source "$ROOT/lib/deploy/healthcheck.sh"
source "$ROOT/lib/deploy/backup.sh"
source "$ROOT/lib/deploy/history.sh"

PASS=0; FAIL=0
t_eq() { # t_eq "label" got want
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); # printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3"; fi
}
t_true() { # t_true "label" cmd...
  local l="$1"; shift
  if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf '  FAIL %s (expected success)\n' "$l"; fi
}
t_false() { local l="$1"; shift; if "$@"; then FAIL=$((FAIL+1)); printf '  FAIL %s (expected failure)\n' "$l"; else PASS=$((PASS+1)); fi; }
section_t() { printf '\n• %s\n' "$1"; }

SBOX="$(mktemp -d)"; trap 'rm -rf "$SBOX"' EXIT
mk() { mkdir -p "$(dirname "$1")"; printf '%s' "${2:-}" > "$1"; }

# ---------------------------------------------------------------------------
section_t "validation helpers"
t_true  "valid domain"        is_valid_domain clicketta.site
t_true  "valid subdomain"     is_valid_domain app.staging.example.com
t_false "invalid domain"      is_valid_domain "not a domain"
t_true  "valid email"         is_valid_email a@b.co
t_false "invalid email"       is_valid_email "nope"
t_true  "abs path"            is_abs_path /var/www
t_false "rel path"            is_abs_path var/www
t_eq    "slugify"             "$(slugify clicketta.site)" clicketta

# ---------------------------------------------------------------------------
section_t "config kv + index round-trips"
CF="$SBOX/test.conf"
kv_set "$CF" host 1.2.3.4
kv_set "$CF" user deploy
kv_set "$CF" host 5.6.7.8   # replace
t_eq "kv replace" "$(kv_get "$CF" host)" 5.6.7.8
t_eq "kv get user" "$(kv_get "$CF" user)" deploy
t_eq "kv missing"  "$(kv_get "$CF" nope)" ""

SRVMGR_HOME="$SBOX/cfg"; SRVMGR_INDEX="$SRVMGR_HOME/sites.index"; SRVMGR_GLOBAL="$SRVMGR_HOME/config"
mkdir -p "$SRVMGR_HOME"; : > "$SRVMGR_INDEX"
index_set clicketta.site prod
index_set blog.example.com prod
index_set clicketta.site staging   # move to another server
t_eq "index resolve" "$(index_get_server clicketta.site)" staging
t_eq "index other"   "$(index_get_server blog.example.com)" prod
index_remove blog.example.com
t_eq "index removed" "$(index_get_server blog.example.com)" ""

# ---------------------------------------------------------------------------
section_t "framework / package-manager detection (remote payload run locally)"
mk "$SBOX/laravel/artisan" ""
mk "$SBOX/laravel/composer.json" '{"require":{"php":"^8.3","laravel/framework":"^11","laravel/horizon":"^5","laravel/octane":"^2"}}'
mk "$SBOX/laravel/.env" $'APP_NAME="Clicketta"\nQUEUE_CONNECTION=redis\nREDIS_HOST=127.0.0.1\n'
mkdir -p "$SBOX/laravel/public"
mk "$SBOX/wp/wp-config.php" "<?php"
mk "$SBOX/next/package.json" '{"dependencies":{"next":"14","react":"18"}}'
mk "$SBOX/next/next.config.js" ""; mk "$SBOX/next/pnpm-lock.yaml" ""
mk "$SBOX/vue/package.json" '{"dependencies":{"vue":"3"}}'; mk "$SBOX/vue/yarn.lock" ""
mk "$SBOX/static/index.html" "<html>"
mk "$SBOX/bun/package.json" '{"dependencies":{"react":"18"}}'; mk "$SBOX/bun/bun.lockb" ""

# Run discovery snippets via LOCAL bash (same payload discover_collect sends).
disc() {
  local root="$1" payload
  payload="$(cat <<EOF
set -u
ROOT=$(shq "$root")
APP_ROOT="\$ROOT"
for cand in "\$ROOT" "\$(dirname "\$ROOT")"; do
  if [ -e "\$cand/composer.json" ] || [ -e "\$cand/package.json" ] || [ -e "\$cand/artisan" ] || [ -d "\$cand/.git" ]; then
    APP_ROOT="\$cand"; break
  fi
done
echo "app_root=\$APP_ROOT"
$(_disc_framework_snippet)
$(_disc_node_snippet)
$(_disc_php_snippet)
EOF
)"
  printf '%s\n' "$payload" | bash
}
val() { printf '%s\n' "$1" | grep "^$2=" | head -1 | cut -d= -f2-; }

OUT="$(disc "$SBOX/laravel/public")"
t_eq "laravel fw"      "$(val "$OUT" framework)" laravel
t_eq "laravel approot" "$(val "$OUT" app_root)" "$SBOX/laravel"
t_eq "laravel php"     "$(val "$OUT" php_version)" 8.3
t_eq "laravel appname" "$(val "$OUT" app_name)" Clicketta
t_eq "laravel queue"   "$(val "$OUT" queue)" 1
t_eq "laravel redis"   "$(val "$OUT" redis)" 1
t_eq "laravel horizon" "$(val "$OUT" horizon)" 1
t_eq "laravel octane"  "$(val "$OUT" octane)" 1
t_eq "wp fw"      "$(val "$(disc "$SBOX/wp")" framework)" wordpress
OUT="$(disc "$SBOX/next")"; t_eq "next fw" "$(val "$OUT" framework)" nextjs; t_eq "next pm" "$(val "$OUT" node_pm)" pnpm
OUT="$(disc "$SBOX/vue")";  t_eq "vue fw"  "$(val "$OUT" framework)" vue;    t_eq "vue pm"  "$(val "$OUT" node_pm)" yarn
t_eq "static fw" "$(val "$(disc "$SBOX/static")" framework)" static
OUT="$(disc "$SBOX/bun")";  t_eq "bun pm"  "$(val "$OUT" node_pm)" bun

# discover_parse must set DISC_* in the CURRENT shell (regression: was piped,
# which ran it in a subshell and left DISC_FRAMEWORK unbound under set -u).
( set -u
  discover_parse <<<$'app_root=/var/www/x\nframework=laravel\nphp_version=8.3\nredis=1'
  [[ "$DISC_FRAMEWORK" == laravel && "$DISC_APP_ROOT" == /var/www/x && "$DISC_REDIS" == 1 ]]
) && t_eq "discover_parse sets globals" ok ok || t_eq "discover_parse sets globals" fail ok

# ---------------------------------------------------------------------------
section_t "nginx rendering"
R1="$(nginx_render clicketta.site /var/www/clicketta/public laravel /run/php/php8.3-fpm.sock '')"
t_true "laravel has fastcgi"  grep -q "fastcgi_pass unix:/run/php/php8.3-fpm.sock" <<<"$R1"
t_true "laravel server_name"  grep -q "server_name clicketta.site;" <<<"$R1"
t_true "laravel root"         grep -q "root /var/www/clicketta/public;" <<<"$R1"
R2="$(nginx_render app.io /var/www/app nextjs '' 127.0.0.1:3000)"
t_true "proxy pass" grep -q "proxy_pass http://127.0.0.1:3000;" <<<"$R2"
R3="$(nginx_render spa.io /var/www/spa/dist react '' '')"
t_true "spa fallback" grep -q "try_files .* /index.html;" <<<"$R3"

# ---------------------------------------------------------------------------
section_t ".env credential editing (db_set_env_creds executed locally)"
ssh_script() { [ "${1:-}" = "--sudo" ] && shift; bash; }   # run 'remote' payload locally
APP="$SBOX/dbapp"; mkdir -p "$APP"
printf 'APP_NAME=Demo\nDB_CONNECTION=sqlite\nAPP_ENV=local\n' | db_write_env "$APP" >/dev/null
db_set_env_creds "$APP" clk clkuser sekret123 >/dev/null
t_eq "env conn"  "$(kv_get "$APP/.env" DB_CONNECTION)" mysql
t_eq "env db"    "$(kv_get "$APP/.env" DB_DATABASE)" clk
t_eq "env user"  "$(kv_get "$APP/.env" DB_USERNAME)" clkuser
t_eq "env pass"  "$(kv_get "$APP/.env" DB_PASSWORD)" sekret123
t_eq "env kept"  "$(kv_get "$APP/.env" APP_NAME)" Demo
P="$(db_gen_password)"; t_eq "genpass length" "${#P}" 24
# Must not abort under pipefail+set -e (regression: tr|head -c SIGPIPE'd → 141).
( set -eo pipefail; pp="$(db_gen_password)"; [[ ${#pp} -eq 24 ]] ) \
  && t_eq "genpass pipefail-safe" ok ok || t_eq "genpass pipefail-safe" fail ok
unset -f ssh_script

# ---------------------------------------------------------------------------
section_t "remote payload syntax lint (bash -n on everything we send)"
LINTFAIL=0
lint() { local tmp; tmp="$(mktemp)"; cat > "$tmp"; if ! bash -n "$tmp" 2>/tmp/srvmgr-lint.err; then echo "  FAIL lint $CUR"; cat /tmp/srvmgr-lint.err; LINTFAIL=1; fi; rm -f "$tmp"; }
ssh_script()  { [ "${1:-}" = "--sudo" ] && shift; lint; }
ssh_exec()    { printf '%s\n' "$1" | lint; }
ssh_sudo()    { printf '%s\n' "$1" | lint; }
ssh_app_exec(){ printf '%s\n' "$2" | lint; }
REMOTE_SITES="/etc/server-manager/sites"; REMOTE_BACKUPS="/var/backups/server-manager"; REMOTE_ETC="/etc/server-manager"

CUR=git_sha;    deploy_git_sha /a >/dev/null 2>&1 || true
CUR=git_pull;   deploy_git_pull /a main >/dev/null 2>&1 || true
CUR=git_reset;  deploy_git_reset /a HEAD~1 >/dev/null 2>&1 || true
CUR=composer;   deploy_composer /a >/dev/null 2>&1 || true
CUR=node;       deploy_node /a pnpm >/dev/null 2>&1 || true
CUR=down;       deploy_laravel_down /a 8.3 >/dev/null 2>&1 || true
CUR=up;         deploy_laravel_up /a 8.3 >/dev/null 2>&1 || true
CUR=migrate;    deploy_laravel_migrate /a 8.3 >/dev/null 2>&1 || true
CUR=optimize;   deploy_laravel_optimize /a 8.3 >/dev/null 2>&1 || true
CUR=fpm;        deploy_restart_php_fpm 8.3 >/dev/null 2>&1 || true
CUR=sup;        deploy_restart_supervisor >/dev/null 2>&1 || true
CUR=queue;      deploy_queue_restart /a 8.3 >/dev/null 2>&1 || true
CUR=horizon;    deploy_horizon_terminate /a 8.3 >/dev/null 2>&1 || true
CUR=health;     deploy_healthcheck d 1 1 1 1 >/dev/null 2>&1 || true
CUR=backup;     deploy_backup d /a laravel /b/ts >/dev/null 2>&1 || true
CUR=restoredb;  deploy_restore_db /a laravel /b >/dev/null 2>&1 || true
CUR=restoreenv; deploy_restore_env /a /b >/dev/null 2>&1 || true
CUR=history;    history_record d ts a b /bk ok 1.0 >/dev/null 2>&1 || true
CUR=dbinstall;  db_install >/dev/null 2>&1 || true
CUR=dbcreate;   db_create n u p >/dev/null 2>&1 || true
CUR=dbenv;      db_set_env_creds /a n u p >/dev/null 2>&1 || true
CUR=sitewrite;  printf 'domain=d\nframework=laravel\n' | remote_site_write d >/dev/null 2>&1 || true
CUR=nginx;      nginx_render d /r laravel /s '' | nginx_install d >/dev/null 2>&1 || true
if [[ $LINTFAIL -eq 0 ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

# ---------------------------------------------------------------------------
printf '\n────────────────────────────\n'
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
