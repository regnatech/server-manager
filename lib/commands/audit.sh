# shellcheck shell=bash
#
# audit.sh — `server audit [site]` and `server audit fix <id> [site]`
#
# A lightweight security audit: probe how the server is configured, surface
# findings (severity + recommendation), and — for the ones we know how to fix —
# expose a one-shot remediation the UI can trigger with a button.
#
# In --json mode each check is a step (so the UI shows live progress) and the
# result is a single {"t":"data","kind":"audit","items":[...]} event. Each item:
#   {"id","severity":"critical|high|medium|low|info","title","detail",
#    "recommendation","fixable":bool,"fix_label":"..."}
#
# A fix is applied with: server audit fix <id> [site]
#
# The check DECISION logic is split into pure `_audit_eval_*` helpers (no SSH)
# so it can be unit-tested; the SSH calls only gather the raw data.

# Accumulated findings (JSON object strings) for the current run.
_AUDIT_ITEMS=()
_AUDIT_FIX_IDS=()
_AUDIT_COUNT_CRIT=0 _AUDIT_COUNT_HIGH=0 _AUDIT_COUNT_MED=0 _AUDIT_COUNT_LOW=0

# _audit_add <id> <severity> <fixable 0|1> <fix_label> <title> <detail> <recommendation>
_audit_add() {
  local id="$1" sev="$2" fixable="$3" fix_label="$4" title="$5" detail="$6" rec="$7"
  local fx=false; [[ "$fixable" == 1 ]] && { fx=true; _AUDIT_FIX_IDS+=("$id"); }
  _AUDIT_ITEMS+=("{$(json_kv_string id "$id"),$(json_kv_string severity "$sev"),$(json_kv_raw fixable "$fx"),$(json_kv_string fix_label "$fix_label"),$(json_kv_string title "$title"),$(json_kv_string detail "$detail"),$(json_kv_string recommendation "$rec")}")
  case "$sev" in
    critical) _AUDIT_COUNT_CRIT=$((_AUDIT_COUNT_CRIT+1));;
    high)     _AUDIT_COUNT_HIGH=$((_AUDIT_COUNT_HIGH+1));;
    medium)   _AUDIT_COUNT_MED=$((_AUDIT_COUNT_MED+1));;
    *)        _AUDIT_COUNT_LOW=$((_AUDIT_COUNT_LOW+1));;
  esac
  # Human (non-JSON) line.
  if ! json_mode; then
    local glyph color
    case "$sev" in
      critical) color="$C_RED"; glyph="$GLYPH_ERR";;
      high)     color="$C_RED"; glyph="$GLYPH_ERR";;
      medium)   color="$C_YELLOW"; glyph="$GLYPH_WARN";;
      *)        color="$C_BLUE"; glyph="$GLYPH_INFO";;
    esac
    printf '  %s%s %-8s%s %s%s\n' "$color" "$glyph" "[$sev]" "$C_RESET" "$title" \
      "$([[ "$fixable" == 1 ]] && printf ' %s(fixable: server audit fix %s)%s' "$C_GREY" "$id" "$C_RESET")" >&2
    say "      ${C_GREY}${detail}${C_RESET}"
    [[ -n "$rec" ]] && say "      ${C_GREY}→ ${rec}${C_RESET}"
  fi
}

# ---------------------------------------------------------------------------
# Pure decision helpers (unit-tested; no SSH).
# ---------------------------------------------------------------------------

# _audit_eval_sshd <sshd -T output> <key> -> effective value (lowercased)
_audit_eval_sshd() {
  printf '%s\n' "$1" | awk -v k="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" \
    'BEGIN{IGNORECASE=1} tolower($1)==k {print tolower($2); found=1} END{if(!found) print ""}' | head -1
}

# _audit_eval_ufw_inactive <ufw status text> -> 0 if inactive/absent
_audit_eval_ufw_inactive() {
  local t="$1"
  [[ "$t" == *absent* ]] && return 0
  printf '%s' "$t" | grep -qiE 'status:[[:space:]]*active' && return 1
  return 0
}

# _audit_eval_env_mode_loose <octal mode> -> 0 if group/other can access it
# (a .env should be owner- or web-group-readable only; world bits are the risk).
_audit_eval_env_mode_loose() {
  local mode="$1"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  local other="${mode: -1}"
  (( other != 0 ))
}

# _audit_eval_count_security <apt-style output> -> number of security updates
_audit_eval_count_security() {
  printf '%s\n' "$1" | grep -ciE 'security' || true
}

# _audit_eval_nginx_tokens <nginx server_tokens lines> -> 0 if it's an issue
# (on, or left at the insecure default). Only an explicit 'off' clears it.
_audit_eval_nginx_tokens() {
  printf '%s' "$1" | grep -qiE 'server_tokens[[:space:]]+off' && return 1
  return 0
}

# _audit_eval_php_expose <php -i expose_php line> -> 'on' | 'off' | ''
_audit_eval_php_expose() {
  printf '%s\n' "$1" | awk -F'=>' 'NR==1{v=$2; gsub(/[[:space:]]/,"",v); print tolower(v)}'
}

# _audit_eval_open_ports <ss -tlnH output> -> space-separated wildcard-bound
# ports that aren't the expected 22/80/443.
_audit_eval_open_ports() {
  printf '%s\n' "$1" | awk '
    {
      addr=$4
      n=split(addr,a,":"); port=a[n]
      host=substr(addr,1,length(addr)-length(port)-1)
      if (host=="0.0.0.0" || host=="*" || host=="::" || host=="[::]") {
        if (port!="22" && port!="80" && port!="443" && port ~ /^[0-9]+$/) print port
      }
    }' | sort -un | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# Checks — each gathers data over SSH, then evaluates.
# ---------------------------------------------------------------------------

audit_check_ssh() {
  local conf; conf="$(ssh_sudo "sshd -T 2>/dev/null" || true)"
  [[ -z "$conf" ]] && return 0
  local root pass
  root="$(_audit_eval_sshd "$conf" permitrootlogin)"
  pass="$(_audit_eval_sshd "$conf" passwordauthentication)"
  if [[ "$root" == "yes" ]]; then
    _audit_add ssh_root_login high 1 "Disable root SSH login" \
      "SSH permits direct root login" \
      "PermitRootLogin is 'yes'. An attacker who guesses the root password gets full control." \
      "Set PermitRootLogin to 'no' and use a sudo user."
  fi
  if [[ "$pass" == "yes" ]]; then
    _audit_add ssh_password_auth medium 1 "Disable SSH password auth" \
      "SSH accepts password authentication" \
      "PasswordAuthentication is 'yes', exposing the server to brute-force attacks." \
      "Switch to key-based auth and set PasswordAuthentication to 'no' (ensure your key works first)."
  fi
}

audit_check_firewall() {
  local st; st="$(ssh_sudo "command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null || echo absent" || echo absent)"
  if _audit_eval_ufw_inactive "$st"; then
    _audit_add firewall high 1 "Enable a firewall" \
      "No active firewall (ufw inactive or not installed)" \
      "Every listening service is reachable from the internet." \
      "Enable ufw allowing only SSH (22), HTTP (80) and HTTPS (443)."
  fi
}

audit_check_fail2ban() {
  local st; st="$(ssh_sudo "systemctl is-active fail2ban 2>/dev/null || echo inactive" || echo inactive)"
  if [[ "$st" != "active" ]]; then
    _audit_add fail2ban medium 1 "Install fail2ban" \
      "fail2ban is not running" \
      "Brute-force attempts against SSH and web logins are not being throttled or banned." \
      "Install fail2ban to auto-ban repeat offenders."
  fi
}

audit_check_auto_updates() {
  local st; st="$(ssh_sudo "dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii' && echo enabled || echo disabled" || echo disabled)"
  if [[ "$st" != "enabled" ]]; then
    _audit_add auto_updates medium 1 "Enable automatic security updates" \
      "Unattended security upgrades are not configured" \
      "Security patches are not applied automatically, leaving known CVEs open." \
      "Install and enable unattended-upgrades."
  fi
}

audit_check_updates() {
  local out n
  out="$(ssh_sudo "apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -iE '^Inst .*security' || true" || true)"
  n="$(_audit_eval_count_security "$out")"
  if (( n > 0 )); then
    local sev=medium; (( n >= 10 )) && sev=high
    _audit_add pending_updates "$sev" 1 "Apply ${n} pending security updates" \
      "${n} security update(s) available" \
      "Installed packages have published security fixes that are not yet applied." \
      "Run the security upgrades."
  fi
}

audit_check_nginx_tokens() {
  command -v nginx >/dev/null 2>&1 || true
  local out; out="$(ssh_sudo "command -v nginx >/dev/null 2>&1 && nginx -T 2>/dev/null | grep -i server_tokens || echo ''" || true)"
  # Only flag when nginx is present (an empty result with nginx installed = default on).
  ssh_exec "command -v nginx >/dev/null 2>&1" || return 0
  if _audit_eval_nginx_tokens "$out"; then
    _audit_add nginx_server_tokens low 1 "Hide the nginx version" \
      "nginx exposes its version (server_tokens not 'off')" \
      "Response headers and error pages leak the exact nginx version, helping attackers target known CVEs." \
      "Set 'server_tokens off;' and reload nginx."
  fi
}

audit_check_php_expose() {
  local out v; out="$(ssh_sudo "php -i 2>/dev/null | grep -i '^expose_php' || echo ''" || true)"
  [[ -z "$out" ]] && return 0
  v="$(_audit_eval_php_expose "$out")"
  if [[ "$v" == "on" ]]; then
    _audit_add php_expose low 1 "Stop PHP advertising itself" \
      "expose_php is On" \
      "PHP adds an X-Powered-By header revealing its version." \
      "Set expose_php = Off in php.ini."
  fi
}

audit_check_open_ports() {
  local out ports; out="$(ssh_sudo "ss -tlnH 2>/dev/null || ss -tln 2>/dev/null || echo ''" || true)"
  ports="$(_audit_eval_open_ports "$out")"
  if [[ -n "$ports" ]]; then
    _audit_add open_ports low 0 "" \
      "Service(s) listening on all interfaces: ${ports}" \
      "Ports ${ports} are reachable from any network, not just localhost." \
      "Bind internal services (databases, caches) to 127.0.0.1, or restrict them with the firewall."
  fi
}

# Site-level checks (run when a site scope is given; SITE_* already loaded).
audit_check_env_perms() {
  [[ -n "$SITE_APP_ROOT" ]] || return 0
  local mode; mode="$(ssh_exec "stat -c '%a' $(shq "$SITE_APP_ROOT/.env") 2>/dev/null" || true)"
  [[ -z "$mode" ]] && return 0
  if _audit_eval_env_mode_loose "$mode"; then
    _audit_add env_perms high 1 "Tighten .env permissions" \
      ".env is world-accessible (mode ${mode})" \
      "Other users on the box can read database and app credentials from .env." \
      "chmod the .env to 640 (owner + web group only)."
  fi
}

audit_check_env_exposed() {
  [[ -n "$SITE_DOMAIN" ]] || return 0
  local code
  code="$(ssh_exec "curl -s -o /dev/null -w '%{http_code}' --max-time 6 -H $(shq "Host: $SITE_DOMAIN") http://127.0.0.1/.env 2>/dev/null" || true)"
  if [[ "$code" == "200" ]]; then
    _audit_add env_exposed critical 1 "Block .env over HTTP" \
      ".env is downloadable over the web (HTTP 200)" \
      "Anyone can fetch https://${SITE_DOMAIN}/.env and read every secret." \
      "Add an nginx rule denying dotfiles and reload."
  fi
}

audit_check_https() {
  [[ -n "$SITE_DOMAIN" ]] || return 0
  if [[ "$SITE_HTTPS" != "1" ]]; then
    _audit_add https medium 1 "Enable HTTPS" \
      "Site is served over plain HTTP" \
      "Traffic to ${SITE_DOMAIN} (including login sessions) is unencrypted." \
      "Issue a Let's Encrypt certificate."
  fi
}

# ---------------------------------------------------------------------------
# server audit [site]   /   server audit fix <id> [site]
# ---------------------------------------------------------------------------
cmd_audit() {
  local sub="${1:-}"
  if [[ "$sub" == "fix" ]]; then
    shift; _audit_fix "$@"; return
  fi
  if [[ "$sub" == "fixall" ]]; then
    shift; _audit_fixall "$@"; return
  fi
  if [[ "$sub" == "history" ]]; then
    shift; _audit_history "${1:-}"; return
  fi
  if [[ "$sub" == "save" ]]; then
    SRVMGR_AUDIT_SAVE=1; sub="${2:-}"   # scope becomes the site arg (if any)
  fi

  local scope="$sub" server
  if [[ -n "$scope" ]]; then
    server="$(registry_resolve_for_site "$scope" "$OPT_SERVER")"
  else
    server="$(registry_resolve "$OPT_SERVER")"
  fi
  ssh_use_server "$server"

  banner "audit — ${server}${scope:+ / ${scope}}"
  section "Security audit"

  _audit_run_checks "$scope"
  _audit_emit
  [[ "${SRVMGR_AUDIT_SAVE:-0}" == "1" ]] && _audit_save "${scope:-$server}"
}

SRVMGR_AUDIT_DIR="${SRVMGR_AUDIT_DIR:-$SRVMGR_HOME/audits}"

# _audit_history_json <log content: "ts\tcrit\thigh\tmed\tlow" lines> -> array
_audit_history_json() {
  local out="[" first=1 ts c h m l total
  while IFS=$'\t' read -r ts c h m l || [[ -n "$ts" ]]; do
    [[ -z "$ts" ]] && continue
    total=$(( ${c:-0} + ${h:-0} + ${m:-0} + ${l:-0} ))
    (( first )) || out+=","
    out+="{$(json_kv_string at "$ts"),$(json_kv_raw critical "${c:-0}"),$(json_kv_raw high "${h:-0}"),$(json_kv_raw medium "${m:-0}"),$(json_kv_raw low "${l:-0}"),$(json_kv_raw total "$total")}"; first=0
  done <<<"$1"
  out+="]"
  printf '%s' "$out"
}

# Append the current run's counts to the scope's history log.
_audit_save() {
  local key; key="$(slugify "$1")"
  mkdir -p "$SRVMGR_AUDIT_DIR" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$(timestamp)" \
    "$_AUDIT_COUNT_CRIT" "$_AUDIT_COUNT_HIGH" "$_AUDIT_COUNT_MED" "$_AUDIT_COUNT_LOW" \
    >>"$SRVMGR_AUDIT_DIR/${key}.log"
  json_mode || ok "Saved audit snapshot for '${1}'."
}

# server audit history [site]
_audit_history() {
  local scope="${1:-}" server key
  if [[ -n "$scope" ]]; then key="$(slugify "$scope")"
  else server="$(registry_resolve "$OPT_SERVER" 2>/dev/null || echo server)"; key="$(slugify "$server")"; fi
  local log="$SRVMGR_AUDIT_DIR/${key}.log" content=""
  [[ -f "$log" ]] && content="$(cat "$log")"
  if json_mode; then
    ui_emit "{\"t\":\"data\",$(json_kv_string kind audit_history),$(json_kv_raw items "$(_audit_history_json "$content")")}"
    return
  fi
  section "Audit history — ${scope:-$key}"
  if [[ -z "${content//[$'\n'[:space:]]/}" ]]; then info "No saved audits yet (run 'server audit save ${scope}')."; return; fi
  printf '%s\n' "$content" | awk -F'\t' '{printf "  %s  crit %s · high %s · med %s · low %s\n", $1, $2, $3, $4, $5}' >&2
}

# _audit_run_checks <scope> — reset state and run every check as a step.
# Populates _AUDIT_ITEMS / _AUDIT_FIX_IDS / counters. Assumes a server is set.
_audit_run_checks() {
  local scope="$1"
  _AUDIT_ITEMS=(); _AUDIT_FIX_IDS=()
  _AUDIT_COUNT_CRIT=0 _AUDIT_COUNT_HIGH=0 _AUDIT_COUNT_MED=0 _AUDIT_COUNT_LOW=0

  step "Checking SSH configuration"        audit_check_ssh          || true
  step "Checking the firewall"             audit_check_firewall     || true
  step "Checking fail2ban"                 audit_check_fail2ban     || true
  step "Checking automatic updates"        audit_check_auto_updates || true
  step "Checking pending security updates" audit_check_updates      || true
  step "Checking nginx version exposure"   audit_check_nginx_tokens || true
  step "Checking PHP exposure"             audit_check_php_expose   || true
  step "Checking open ports"               audit_check_open_ports   || true

  if [[ -n "$scope" ]] && site_load "$scope" 2>/dev/null; then
    step "Checking .env permissions"   audit_check_env_perms   || true
    step "Checking .env exposure"      audit_check_env_exposed || true
    step "Checking HTTPS"              audit_check_https       || true
  fi
}

# server audit fixall [site] — run the audit, then apply every fixable finding.
_audit_fixall() {
  local scope="${1:-}" server
  if [[ -n "$scope" ]]; then
    server="$(registry_resolve_for_site "$scope" "$OPT_SERVER")"
  else
    server="$(registry_resolve "$OPT_SERVER")"
  fi
  ssh_use_server "$server"
  [[ -n "$scope" ]] && site_load "$scope" 2>/dev/null || true

  banner "audit fixall — ${server}${scope:+ / ${scope}}"
  section "Security audit"
  _audit_run_checks "$scope"

  local ids=("${_AUDIT_FIX_IDS[@]+"${_AUDIT_FIX_IDS[@]}"}")
  if (( ${#ids[@]} == 0 )); then
    ok "Nothing to fix — no auto-fixable findings."
    json_mode && ui_emit "{\"t\":\"data\",$(json_kv_string kind audit_fixall),$(json_kv_raw value "{$(json_kv_raw applied 0),$(json_kv_raw failed 0)}")}"
    return 0
  fi

  section "Applying ${#ids[@]} fix(es)"
  local applied=0 failed=0 id
  for id in "${ids[@]}"; do
    if _audit_apply_fix "$id"; then applied=$((applied+1)); else failed=$((failed+1)); warn "Fix '${id}' failed — continuing."; fi
  done

  ok "Applied ${applied} fix(es); ${failed} failed. Re-run 'server audit' to confirm."
  json_mode && ui_emit "{\"t\":\"data\",$(json_kv_string kind audit_fixall),$(json_kv_raw value "{$(json_kv_raw applied "$applied"),$(json_kv_raw failed "$failed")}")}"
}

# Emit the collected findings (JSON data event, or a TTY summary).
_audit_emit() {
  if json_mode; then
    local items="["; local i first=1
    for i in "${_AUDIT_ITEMS[@]+"${_AUDIT_ITEMS[@]}"}"; do
      (( first )) || items+=","; items+="$i"; first=0
    done
    items+="]"
    ui_emit "{\"t\":\"data\",$(json_kv_string kind audit),$(json_kv_raw items "$items")}"
    return
  fi
  local total=$(( _AUDIT_COUNT_CRIT + _AUDIT_COUNT_HIGH + _AUDIT_COUNT_MED + _AUDIT_COUNT_LOW ))
  if (( total == 0 )); then
    ok "No issues found — the server passed every check."
  else
    report_box "Audit: ${total} finding(s)" \
      "Critical : ${_AUDIT_COUNT_CRIT}" \
      "High     : ${_AUDIT_COUNT_HIGH}" \
      "Medium   : ${_AUDIT_COUNT_MED}" \
      "Low/info : ${_AUDIT_COUNT_LOW}" \
      "Fix one  : server audit fix <id>"
  fi
}

# _audit_fix <id> [site] — apply a single remediation by finding id.
_audit_fix() {
  local id="${1:-}" scope="${2:-}"
  [[ -n "$id" ]] || die "Usage: server audit fix <id> [site]"

  local server
  if [[ -n "$scope" ]]; then
    server="$(registry_resolve_for_site "$scope" "$OPT_SERVER")"
  else
    server="$(registry_resolve "$OPT_SERVER")"
  fi
  ssh_use_server "$server"
  [[ -n "$scope" ]] && site_load "$scope" 2>/dev/null || true

  banner "audit fix — ${id} @ ${server}"
  _audit_apply_fix "$id" || die "Fix failed."
  ok "Applied fix for '${id}'. Re-run 'server audit' to confirm."
}

# _audit_apply_fix <id> — apply a single remediation (server already selected,
# SITE_* loaded for site-scoped fixes). Returns non-zero on failure WITHOUT
# exiting, so 'fixall' can keep going.
_audit_apply_fix() {
  local id="$1" email
  case "$id" in
    ssh_root_login)      step "Disabling root SSH login"    audit_fix_ssh_root_login;;
    ssh_password_auth)   step "Disabling SSH password auth" audit_fix_ssh_password_auth;;
    firewall)            step "Enabling the firewall (ufw)" audit_fix_firewall;;
    fail2ban)            step "Installing fail2ban"         audit_fix_fail2ban;;
    auto_updates)        step "Enabling automatic updates"  audit_fix_auto_updates;;
    pending_updates)     step "Applying security updates"   audit_fix_updates;;
    nginx_server_tokens) step "Hiding the nginx version"    audit_fix_nginx_tokens;;
    php_expose)          step "Disabling expose_php"        audit_fix_php_expose;;
    env_perms)   [[ -n "$SITE_APP_ROOT" ]] || { warn "env_perms needs a site"; return 1; }
                 step "Securing .env permissions" audit_fix_env_perms "$SITE_APP_ROOT";;
    env_exposed) [[ -n "$SITE_DOMAIN" ]] || { warn "env_exposed needs a site"; return 1; }
                 step "Blocking dotfiles in nginx" audit_fix_env_exposed "$SITE_DOMAIN";;
    https)       [[ -n "$SITE_DOMAIN" ]] || { warn "https needs a site"; return 1; }
                 email="$(global_get le_email)"
                 if [[ -z "$email" ]]; then
                   [[ "${SRVMGR_ASSUME_YES:-0}" == "1" ]] && { warn "https fix skipped: no Let's Encrypt email set"; return 1; }
                   email="$(ask_required "Let's Encrypt email")"
                 fi
                 step "Issuing HTTPS certificate" nginx_enable_https "$SITE_DOMAIN" "$email";;
    *) warn "Unknown finding id '${id}'"; return 1;;
  esac
}

# ---------------------------------------------------------------------------
# Fixes (privileged; run via ssh_sudo / ssh_script --sudo).
# ---------------------------------------------------------------------------
_AUDIT_SSHD_DROPIN="/etc/ssh/sshd_config.d/00-server-manager.conf"

audit_fix_ssh_root_login() {
  ssh_script --sudo <<EOF
set -e
d=$(shq "$_AUDIT_SSHD_DROPIN"); mkdir -p "\$(dirname "\$d")"; touch "\$d"
grep -q '^PermitRootLogin' "\$d" 2>/dev/null \
  && sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "\$d" \
  || echo 'PermitRootLogin no' >> "\$d"
sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload; }
echo "root login disabled"
EOF
}

audit_fix_ssh_password_auth() {
  ssh_script --sudo <<EOF
set -e
d=$(shq "$_AUDIT_SSHD_DROPIN"); mkdir -p "\$(dirname "\$d")"; touch "\$d"
grep -q '^PasswordAuthentication' "\$d" 2>/dev/null \
  && sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "\$d" \
  || echo 'PasswordAuthentication no' >> "\$d"
sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload; }
echo "password auth disabled"
EOF
}

audit_fix_firewall() {
  ssh_script --sudo <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
command -v ufw >/dev/null 2>&1 || { apt-get update -y; apt-get install -y ufw; }
ufw allow OpenSSH 2>/dev/null || ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
echo "firewall enabled"
EOF
}

audit_fix_fail2ban() {
  ssh_script --sudo <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then apt-get update -y; apt-get install -y fail2ban
elif command -v dnf >/dev/null 2>&1; then dnf install -y fail2ban
elif command -v yum >/dev/null 2>&1; then yum install -y fail2ban
else echo "no package manager for fail2ban" >&2; exit 1; fi
systemctl enable --now fail2ban
echo "fail2ban active"
EOF
}

audit_fix_auto_updates() {
  ssh_script --sudo <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y unattended-upgrades
echo 'APT::Periodic::Update-Package-Lists "1";' >/etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >>/etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades 2>/dev/null || true
echo "automatic updates enabled"
EOF
}

audit_fix_updates() {
  ssh_sudo "export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get upgrade -y && echo 'security updates applied'"
}

audit_fix_env_perms() {
  local app_root="$1"
  ssh_sudo "f=$(shq "$app_root/.env"); [ -f \"\$f\" ] && { owner=\$(stat -c '%U' \"\$app_root\" 2>/dev/null || echo www-data); chgrp www-data \"\$f\" 2>/dev/null || true; chmod 640 \"\$f\"; echo \"perms set to 640\"; } || echo 'no .env'"
}

audit_fix_nginx_tokens() {
  ssh_script --sudo <<'EOF'
set -e
command -v nginx >/dev/null 2>&1 || { echo "nginx not installed" >&2; exit 1; }
f=/etc/nginx/conf.d/00-server-manager-hardening.conf
echo 'server_tokens off;' > "$f"
nginx -t && { systemctl reload nginx 2>/dev/null || service nginx reload; }
echo "server_tokens off"
EOF
}

audit_fix_php_expose() {
  ssh_script --sudo <<'EOF'
set -e
command -v php >/dev/null 2>&1 || { echo "php not installed" >&2; exit 1; }
changed=0
for ini in $(php -i 2>/dev/null | awk -F'=> ' '/Loaded Configuration File|Additional .ini files/{print $2}' | tr ',' '\n' | grep -E '\.ini$'); do
  [ -f "$ini" ] || continue
  if grep -qiE '^[; ]*expose_php' "$ini"; then
    sed -i -E 's/^[; ]*expose_php.*/expose_php = Off/I' "$ini"; changed=1
  fi
done
# Also drop a CLI/FPM override to be safe.
for d in /etc/php/*/fpm/conf.d /etc/php.d; do
  [ -d "$d" ] && { echo 'expose_php = Off' > "$d/99-server-manager.ini"; changed=1; }
done
systemctl reload 'php*-fpm' 2>/dev/null || systemctl restart php-fpm 2>/dev/null || true
[ "$changed" = 1 ] && echo "expose_php disabled" || echo "expose_php already off"
EOF
}

audit_fix_env_exposed() {
  local domain="$1"
  ssh_script --sudo <<EOF
set -e
domain=$(shq "$domain")
for f in "/etc/nginx/sites-available/\${domain}" "/etc/nginx/sites-available/\${domain}.conf" "/etc/nginx/conf.d/\${domain}.conf"; do
  [ -f "\$f" ] || continue
  grep -q 'location ~ /\\\\.' "\$f" && { echo "deny rule already present"; exit 0; }
  # Insert a dotfile-deny block just inside the first server { ... }.
  awk 'BEGIN{done=0} /server[[:space:]]*\{/ && !done {print; print "    location ~ /\\\\.(?!well-known).* { deny all; }"; done=1; next} {print}' "\$f" >"\$f.tmp" && mv "\$f.tmp" "\$f"
  nginx -t && { systemctl reload nginx || service nginx reload; }
  echo "dotfiles blocked"; exit 0
done
echo "nginx vhost for \${domain} not found" >&2; exit 1
EOF
}
