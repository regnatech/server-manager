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

source "$ROOT/lib/core/json.sh"
source "$ROOT/lib/core/ui.sh"
source "$ROOT/lib/core/notify.sh"
source "$ROOT/lib/core/util.sh"
source "$ROOT/lib/core/config.sh"
source "$ROOT/lib/discovery/framework.sh"
source "$ROOT/lib/discovery/git.sh"
source "$ROOT/lib/discovery/node.sh"
source "$ROOT/lib/discovery/php.sh"
source "$ROOT/lib/discovery/discover.sh"
source "$ROOT/lib/providers/nginx.sh"
source "$ROOT/lib/providers/database.sh"
source "$ROOT/lib/providers/php.sh"
source "$ROOT/lib/providers/workers.sh"
source "$ROOT/lib/providers/toolchain.sh"
source "$ROOT/lib/commands/update.sh"
source "$ROOT/lib/commands/audit.sh"
source "$ROOT/lib/commands/metrics.sh"
source "$ROOT/lib/commands/git.sh"
source "$ROOT/lib/commands/logs.sh"
source "$ROOT/lib/commands/diff.sh"
source "$ROOT/lib/commands/release.sh"
source "$ROOT/lib/commands/uptime.sh"
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
CUR=dbwriteenv; printf 'X=1\n' | db_write_env /a >/dev/null 2>&1 || true
CUR=phpinstall; php_install 8.3 >/dev/null 2>&1 || true
CUR=phpsocket;  php_socket_for 8.3 >/dev/null 2>&1 || true
CUR=dbimport;   db_run_import /a /tmp/x.sql.gz >/dev/null 2>&1 || true
CUR=dbexport;   db_run_export /a >/dev/null 2>&1 || true
CUR=sched;      workers_install_scheduler clk /a 8.3 >/dev/null 2>&1 || true
CUR=supens;     workers_ensure_supervisor >/dev/null 2>&1 || true
CUR=whorizon;   workers_install_supervisor clk /a 8.3 horizon >/dev/null 2>&1 || true
CUR=wqueue;     workers_install_supervisor clk /a 8.3 queue >/dev/null 2>&1 || true
CUR=wstatus;    workers_status clk >/dev/null 2>&1 || true
CUR=wrestart;   workers_restart clk >/dev/null 2>&1 || true
CUR=wremove;    workers_remove clk >/dev/null 2>&1 || true
CUR=schedstat;  workers_scheduler_status clk >/dev/null 2>&1 || true
CUR=schedrm;    workers_scheduler_remove clk >/dev/null 2>&1 || true
CUR=cronlist;   workers_cron_list clk /a >/dev/null 2>&1 || true
CUR=cronadd;    workers_cron_add clk '0 3 * * *' 'php artisan x' /a >/dev/null 2>&1 || true
CUR=cronrm;     workers_cron_remove clk 2 >/dev/null 2>&1 || true
CUR=sitewrite;  printf 'domain=d\nframework=laravel\n' | remote_site_write d >/dev/null 2>&1 || true
CUR=nginx;      nginx_render d /r laravel /s '' | nginx_install d >/dev/null 2>&1 || true
CUR=tc_composer; toolchain_ensure_composer >/dev/null 2>&1 || true
CUR=tc_node;     toolchain_ensure_node >/dev/null 2>&1 || true
CUR=tc_pm_npm;   toolchain_ensure_pm npm  >/dev/null 2>&1 || true
CUR=tc_pm_pnpm;  toolchain_ensure_pm pnpm >/dev/null 2>&1 || true
CUR=tc_pm_yarn;  toolchain_ensure_pm yarn >/dev/null 2>&1 || true
CUR=tc_pm_bun;   toolchain_ensure_pm bun  >/dev/null 2>&1 || true
CUR=tc_git;      toolchain_ensure_git >/dev/null 2>&1 || true
CUR=tc_phpext;   toolchain_ensure_php_ext 8.3 gd >/dev/null 2>&1 || true
CUR=tc_unzip;    toolchain_ensure_unzip >/dev/null 2>&1 || true
CUR=fix_sshroot; audit_fix_ssh_root_login >/dev/null 2>&1 || true
CUR=fix_sshpw;   audit_fix_ssh_password_auth >/dev/null 2>&1 || true
CUR=fix_ufw;     audit_fix_firewall >/dev/null 2>&1 || true
CUR=fix_f2b;     audit_fix_fail2ban >/dev/null 2>&1 || true
CUR=fix_autoup;  audit_fix_auto_updates >/dev/null 2>&1 || true
CUR=fix_updates; audit_fix_updates >/dev/null 2>&1 || true
CUR=fix_envperm; audit_fix_env_perms /a >/dev/null 2>&1 || true
CUR=fix_envexp;  audit_fix_env_exposed example.com >/dev/null 2>&1 || true
CUR=fix_tokens;  audit_fix_nginx_tokens >/dev/null 2>&1 || true
CUR=fix_expose;  audit_fix_php_expose >/dev/null 2>&1 || true
CUR=metrics;     _metrics_gather >/dev/null 2>&1 || true
CUR=git_run;     _git_run /a "git status" >/dev/null 2>&1 || true
CUR=git_apply;   _git_apply_stdin /a x.php "data" >/dev/null 2>&1 || true
if [[ $LINTFAIL -eq 0 ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

# ---------------------------------------------------------------------------
section_t "JSON event protocol (--json mode emitter)"

# json_escape handles the characters JSON requires.
t_eq "escape quote"      "$(json_escape 'a"b')"          'a\"b'
t_eq "escape backslash"  "$(json_escape 'a\b')"          'a\\b'
t_eq "escape tab"        "$(json_escape "$(printf 'a\tb')")" 'a\tb'
t_eq "json_str quotes"   "$(json_str 'hi')"              '"hi"'
t_eq "json_object"       "$(json_object a 1 b 2)"        '{"a":"1","b":"2"}'

# json_mode reflects the env switch.
( SRVMGR_JSON=1; json_mode ); t_eq "json_mode on"  "$?" 0
( unset SRVMGR_JSON; json_mode ); t_eq "json_mode off" "$?" 1

# The emitter functions, under SRVMGR_JSON=1, produce one valid JSON object per
# line. We validate with a tiny pure-bash brace/quote-aware check (no jq/node):
# every emitted line must start with '{' and end with '}' and have balanced,
# unescaped double quotes.
json_line_ok() {
  local l="$1"
  [[ "$l" == '{'*'}' ]] || return 1
  # count unescaped quotes — must be even
  local q="${l//\\\"/}"; q="${q//[!\"]/}"
  (( ${#q} % 2 == 0 ))
}

emit_capture() {
  ( SRVMGR_JSON=1; exec 3>&1; _UI_EVENT_FD=3; "$@" )
}

JOUT="$(emit_capture section 'Deploy')"
t_eq   "section event"   "$JOUT" '{"t":"section","label":"Deploy"}'
t_true "section valid"   json_line_ok "$JOUT"

JOUT="$(emit_capture warn 'has "quotes" here')"
t_true "warn valid json" json_line_ok "$JOUT"
t_eq   "warn level"      "$(printf '%s' "$JOUT" | grep -c '"level":"warn"')" 1

# step success + failure both emit start/end pairs with an ok flag.
JOUT="$(emit_capture step 'noop' true)"
t_eq   "step lines"      "$(printf '%s\n' "$JOUT" | grep -c '^{')" 2
t_true "step_start"      grep -q '"t":"step_start"' <<<"$JOUT"
t_true "step_end ok"     grep -q '"t":"step_end".*"ok":true' <<<"$JOUT"

JOUT="$(emit_capture step 'boom' bash -c 'exit 3')"
t_true "step_end fail"   grep -q '"t":"step_end".*"ok":false' <<<"$JOUT"

# report_box splits "Label : value" lines into a fields object.
JOUT="$(emit_capture report_box 'Done' 'URL : https://x.test' 'PHP : 8.3')"
t_true "report event"    grep -q '"t":"report"' <<<"$JOUT"
t_true "report keeps url" grep -q '"URL":"https://x.test"' <<<"$JOUT"
t_true "report fields"    grep -q '"PHP":"8.3"' <<<"$JOUT"

# Every emitted line passes the structural check.
ALL_OK=1
while IFS= read -r _l; do [[ -z "$_l" ]] && continue; json_line_ok "$_l" || ALL_OK=0; done <<<"$JOUT"
t_eq "all report lines valid" "$ALL_OK" 1

# ---------------------------------------------------------------------------
section_t "self-healing deploy (_deploy_try + diagnosers)"

TRY="$SBOX/try"; mkdir -p "$TRY"

# --- _deploy_try control flow (diagnoser receives the captured logfile) ---

# 1. Happy path: the step succeeds, so the diagnoser never runs.
_t_ok()       { return 0; }
_t_diag_log() { echo ran >>"$TRY/diag"; return 0; }
rm -f "$TRY/diag"
_deploy_try "ok step" _t_diag_log -- _t_ok >/dev/null 2>&1
t_eq    "success returns 0"          "$?" 0
t_false "diagnoser not run on success" test -f "$TRY/diag"

# 2. Step fails once; diagnoser remediates so the retry passes.
rm -f "$TRY/healed"
_t_flaky()   { [ -f "$TRY/healed" ]; }    # fails until healed exists
_t_diag_heal() { touch "$TRY/healed"; return 0; }
_deploy_try "flaky step" _t_diag_heal -- _t_flaky >/dev/null 2>&1
t_eq   "heal-then-retry returns 0" "$?" 0
t_true "remediation ran"           test -f "$TRY/healed"

# 3. Diagnoser declines (returns non-zero): no retry, surface the failure.
_t_fail()        { return 1; }
_t_diag_decline() { return 1; }
_deploy_try "broken step" _t_diag_decline -- _t_fail >/dev/null 2>&1
t_eq "diagnoser decline returns non-zero" "$?" 1

# 4. The diagnoser actually receives the failing step's captured output.
_t_run_err()  { echo "MARKER_NEEDS_GD ext-gd missing" >&2; return 1; }
_t_diag_see() { grep -q MARKER_NEEDS_GD "$1" && { touch "$TRY/sawit"; return 0; } || return 1; }
rm -f "$TRY/sawit"
_deploy_try "errstep" _t_diag_see -- _t_run_err >/dev/null 2>&1 || true
t_true "diagnoser receives captured output" test -f "$TRY/sawit"

# --- diagnoser decision logic (stub the installers, assert the choice) ---
DIAGLOG="$TRY/diag.log"
toolchain_ensure_php_ext() { echo "php_ext:$2" >"$TRY/picked"; }
toolchain_ensure_unzip()   { echo "unzip"      >"$TRY/picked"; }
toolchain_ensure_git()     { echo "git"        >"$TRY/picked"; }
toolchain_ensure_composer(){ echo "composer"   >"$TRY/picked"; }
toolchain_ensure_pm()      { echo "pm:$1"      >"$TRY/picked"; }

printf 'Problem 1: laravel/framework requires ext-gd * -> it is missing\n' >"$DIAGLOG"
_diagnose_composer "$DIAGLOG" >/dev/null 2>&1
t_eq "composer: requires ext-gd → install gd"     "$(cat "$TRY/picked")" "php_ext:gd"

printf 'the requested PHP extension intl is missing from your system\n' >"$DIAGLOG"
_diagnose_composer "$DIAGLOG" >/dev/null 2>&1
t_eq "composer: 'PHP extension intl' → install intl" "$(cat "$TRY/picked")" "php_ext:intl"

printf 'you need to enable the unzip command to use prefer-dist\n' >"$DIAGLOG"
_diagnose_composer "$DIAGLOG" >/dev/null 2>&1
t_eq "composer: unzip hint → install unzip"        "$(cat "$TRY/picked")" "unzip"

printf 'composer: command not found\n' >"$DIAGLOG"
_diagnose_composer "$DIAGLOG" >/dev/null 2>&1
t_eq "composer: missing binary → install composer" "$(cat "$TRY/picked")" "composer"

printf 'some unrelated failure\n' >"$DIAGLOG"
_diagnose_composer "$DIAGLOG" >/dev/null 2>&1
t_eq "composer: fallback → ensure composer"        "$(cat "$TRY/picked")" "composer"

SITE_NODE_PM=pnpm
printf 'sh: 1: pnpm: not found\n' >"$DIAGLOG"
_diagnose_node "$DIAGLOG" >/dev/null 2>&1
t_eq "node: pm not found → install pnpm"           "$(cat "$TRY/picked")" "pm:pnpm"

printf 'npm ERR! ENOSPC: no space left on device\n' >"$DIAGLOG"
_diagnose_node "$DIAGLOG" >/dev/null 2>&1
t_eq "node: ENOSPC → no auto-fix (non-zero)"       "$?" 1

# ---------------------------------------------------------------------------
section_t "notifications (payload builders)"
t_eq "notify emoji success" "$(_notify_emoji success)" "✅"
t_eq "notify emoji failure" "$(_notify_emoji failure)" "❌"
t_eq "notify emoji info"    "$(_notify_emoji whatever)" "ℹ️"
t_eq "notify format w/ body" "$(_notify_format success 'Deployed' 'on prod')" "$(printf '✅ Deployed\non prod')"
t_eq "notify format title only" "$(_notify_format failure 'Boom' '')" "❌ Boom"
t_eq "slack payload escapes"  "$(_notify_slack_payload 'he said "hi"')" '{"text":"he said \"hi\""}'
t_true "slack payload valid json" json_line_ok "$(_notify_slack_payload 'plain text')"

# ---------------------------------------------------------------------------
section_t "security audit (parsers + findings)"

SSHDT="$(printf 'permitrootlogin yes\npasswordauthentication no\nport 22\n')"
t_eq "sshd permitrootlogin"  "$(_audit_eval_sshd "$SSHDT" permitrootlogin)" "yes"
t_eq "sshd passwordauth no"  "$(_audit_eval_sshd "$SSHDT" passwordauthentication)" "no"
t_eq "sshd missing key"      "$(_audit_eval_sshd "$SSHDT" x11forwarding)" ""

_audit_eval_ufw_inactive "Status: active";   t_eq "ufw active → not inactive" "$?" 1
_audit_eval_ufw_inactive "Status: inactive"; t_eq "ufw inactive"             "$?" 0
_audit_eval_ufw_inactive "absent";           t_eq "ufw absent → inactive"    "$?" 0

_audit_eval_env_mode_loose 644; t_eq "mode 644 loose"     "$?" 0
_audit_eval_env_mode_loose 640; t_eq "mode 640 not loose" "$?" 1
_audit_eval_env_mode_loose 600; t_eq "mode 600 not loose" "$?" 1
_audit_eval_env_mode_loose 666; t_eq "mode 666 loose"     "$?" 0

t_eq "security update count" "$(_audit_eval_count_security "$(printf 'Inst libc security\nInst foo\nInst bar security\n')")" 2

_audit_eval_nginx_tokens "    server_tokens off;"; t_eq "nginx tokens off → ok"   "$?" 1
_audit_eval_nginx_tokens "";                       t_eq "nginx tokens default → issue" "$?" 0
_audit_eval_nginx_tokens "server_tokens on;";      t_eq "nginx tokens on → issue" "$?" 0
t_eq "php expose On"  "$(_audit_eval_php_expose 'expose_php => On => On')"  "on"
t_eq "php expose Off" "$(_audit_eval_php_expose 'expose_php => Off => Off')" "off"
OPENSS="$(printf 'LISTEN 0 128 0.0.0.0:3306 0.0.0.0:*\nLISTEN 0 128 127.0.0.1:6379 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:80 0.0.0.0:*\nLISTEN 0 128 [::]:443 [::]:*\n')"
t_eq "open ports: only risky wildcard non-80/443" "$(_audit_eval_open_ports "$OPENSS")" "3306"

# --- metrics parsers ---
t_eq "load parse"  "$(_metrics_eval_load '0.42 0.55 0.61 1/234 5678')" "0.42 0.55 0.61"
MEMF="$(printf '              total        used        free\nMem:    8000000000  2100000000  900000000\nSwap:   0 0 0\n')"
t_eq "mem parse"   "$(_metrics_eval_mem "$MEMF")" "2100000000 8000000000 26"
DFF="$(printf 'Filesystem 1B-blocks Used Available Capacity Mounted\n/dev/sda1 50000000000 12000000000 38000000000 24%% /\n')"
t_eq "disk parse"  "$(_metrics_eval_disk "$DFF")" "12000000000 50000000000 24"
t_eq "uptime parse" "$(_metrics_eval_uptime '1234567.89 9876543.21')" "1234567"
t_eq "human bytes GB" "$(_metrics_human 2100000000)" "2.0 GB"
t_eq "uptime human"   "$(_metrics_uptime_human 1234567)" "14d 6h 56m"
t_eq "section slice"  "$(_metrics_section "$(printf '###LOAD\n0.1 0.2 0.3\n###CPUS\n4\n###END\n')" CPUS)" "4"

# --- git parsers ---
FS=$'\x1f'
GLOG="abc123${FS}abc${FS}def456 ghi789${FS}Ada L${FS}2026-06-01${FS}2 days ago${FS} (HEAD -> main, origin/main, tag: v1.4)${FS}Fix the bug"
GITEMS="$(_git_log_json "$GLOG")"
t_true "git log: is a json array"   grep -qE '^\[\{.*\}\]$' <<<"$GITEMS"
t_true "git log: subject kept"      grep -q '"subject":"Fix the bug"' <<<"$GITEMS"
t_true "git log: two parents"       grep -q '"parents":\["def456","ghi789"\]' <<<"$GITEMS"
t_true "git log: refs parsed"       grep -q '"refs":\["HEAD -> main","origin/main","tag: v1.4"\]' <<<"$GITEMS"
t_eq   "git refs empty"             "$(_git_refs_json '')" "[]"
t_eq   "git refs single"            "$(_git_refs_json ' (origin/main)')" '["origin/main"]'

GSTAT="$(_git_status_json main origin/main 2 1 "$(printf ' M app/Foo.php\n?? new.txt\n')")"
t_true "git status: branch"         grep -q '"branch":"main"' <<<"$GSTAT"
t_true "git status: ahead 2"        grep -q '"ahead":2' <<<"$GSTAT"
t_true "git status: not clean"      grep -q '"clean":false' <<<"$GSTAT"
t_true "git status: dirty paths"    grep -q '"dirty":\["app/Foo.php","new.txt"\]' <<<"$GSTAT"
GSTAT_CLEAN="$(_git_status_json main origin/main 0 0 "")"
t_true "git status: clean when empty" grep -q '"clean":true' <<<"$GSTAT_CLEAN"

GBR="$(_git_branches_json "$(printf 'main%s*\ndevelop%s \norigin/main%s \n' "$FS" "$FS" "$FS")")"
t_true "git branches: current main"  grep -q '"name":"main","current":true' <<<"$GBR"
t_true "git branches: remote flag"   grep -q '"name":"origin/main","current":false,"remote":true' <<<"$GBR"

GCONF="$(_git_conflict_item_json app/X.php 'our code' 'their code' '<<<<<<< HEAD')"
t_true "git conflict item json"      json_line_ok "$GCONF"
t_true "git conflict keeps ours"     grep -q '"ours":"our code"' <<<"$GCONF"

# --- logs ---
LJSON="$(_logs_lines_json "$(printf 'line one\nERROR: "boom"\nline three\n')")"
t_true "logs lines: json array"  grep -qE '^\[.*\]$' <<<"$LJSON"
t_true "logs lines: escaped"     grep -q '"ERROR: \\"boom\\""' <<<"$LJSON"
t_eq   "logs lines: count"       "$(printf '%s' "$LJSON" | grep -o '","' | wc -l)" 2

# --- deploy diff ---
MIGJSON="$(_diff_migrations_json "$(printf 'database/migrations/2026_06_01_000000_create_orders.php\ndatabase/migrations/2026_06_02_000000_add_index.php\n')")"
t_true "diff migrations: array"   grep -qE '^\[.*\]$' <<<"$MIGJSON"
t_true "diff migrations: basename" grep -q '"2026_06_01_000000_create_orders.php"' <<<"$MIGJSON"
t_eq   "diff migrations: empty"   "$(_diff_migrations_json '')" "[]"

# --- atomic releases ---
RNAMES="$(printf '20260629_120000\n20260628_090000\n20260627_080000\n')"
RLJSON="$(_release_list_json "$RNAMES" 20260628_090000)"
t_true "release list: current flagged" grep -q '"name":"20260628_090000","current":true' <<<"$RLJSON"
t_true "release list: others not current" grep -q '"name":"20260629_120000","current":false' <<<"$RLJSON"
# keep 2 newest + current; names a..e newest-first, current=d
RPRUNE="$(_release_prune_select "$(printf 'a\nb\nc\nd\ne\n')" 2 d)"
t_eq "release prune: removes beyond keep except current" "$(printf '%s' "$RPRUNE" | tr '\n' ' ' | sed 's/ $//')" "c e"

# --- uptime ---
t_eq "uptime 200 up"    "$(_uptime_eval '200 0.123')" "200 123 1"
t_eq "uptime 301 up"    "$(_uptime_eval '301 0.050')" "301 50 1"
t_eq "uptime 503 down"  "$(_uptime_eval '503 1.5')"   "503 1500 0"
t_eq "uptime timeout"   "$(_uptime_eval '000 0')"     "0 0 0"

# Finding registration yields a valid JSON object with a boolean 'fixable'.
_AUDIT_ITEMS=()
_audit_add testid high 1 "Fix it" "A title" 'detail with "quote"' "do the thing" 2>/dev/null
t_eq   "one finding registered" "${#_AUDIT_ITEMS[@]}" 1
AITEM="${_AUDIT_ITEMS[0]}"
t_true "finding is valid json"  json_line_ok "$AITEM"
t_true "fixable is boolean"     grep -q '"fixable":true' <<<"$AITEM"
t_true "severity recorded"      grep -q '"severity":"high"' <<<"$AITEM"
t_eq   "high counter bumped"    "$_AUDIT_COUNT_HIGH" 1

# audit history builder (tab-separated ts/crit/high/med/low → totals)
AH="$(_audit_history_json "$(printf '2026-06-28T10:00\t1\t2\t1\t0\n2026-06-29T10:00\t0\t1\t1\t2\n')")"
t_true "audit history: array"     grep -qE '^\[.*\]$' <<<"$AH"
t_true "audit history: first total 4" grep -q '"at":"2026-06-28T10:00","critical":1,"high":2,"medium":1,"low":0,"total":4' <<<"$AH"
t_true "audit history: second total 4" grep -q '"at":"2026-06-29T10:00","critical":0,"high":1,"medium":1,"low":2,"total":4' <<<"$AH"
t_eq   "audit history empty"      "$(_audit_history_json '')" "[]"

# fixall only collects the auto-fixable ids.
_AUDIT_ITEMS=(); _AUDIT_FIX_IDS=()
_audit_add firewall high 1 "fw" t d r 2>/dev/null
_audit_add open_ports low 0 "" t d r 2>/dev/null
_audit_add fail2ban medium 1 "f2b" t d r 2>/dev/null
t_eq "fixall: 2 fixable ids"  "${#_AUDIT_FIX_IDS[@]}" 2
t_eq "fixall: ids in order"   "${_AUDIT_FIX_IDS[*]}" "firewall fail2ban"

# ---------------------------------------------------------------------------
printf '\n────────────────────────────\n'
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
