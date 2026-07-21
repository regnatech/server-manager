# shellcheck shell=bash
#
# add.sh — `server add [domain] [root]`
#
# The wizard: probe the server, auto-discover the project, confirm only what
# could be detected, prompt for the rest, persist everything remotely and
# provision nginx (+ optional HTTPS). The user never edits a config file.

# Let the user pick a framework when discovery couldn't (rare).
_choose_framework() {
  say "  Could not auto-detect the project type. Choose one:" >&2
  local opts=(laravel symfony wordpress statamic static nodejs react vue nuxt nextjs reverse_proxy)
  local i=1 o
  for o in "${opts[@]}"; do
    printf '    %2d) %s\n' "$i" "$(framework_label "$o")" >&2
    i=$((i+1))
  done
  local sel
  while :; do
    sel="$(ask "Type number" "11")"
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#opts[@]} )); then
      printf '%s' "${opts[$((sel-1))]}"; return 0
    fi
    warn "Enter a number between 1 and ${#opts[@]}."
  done
}

cmd_add() {
  # Headless two-phase contract: `--json add --plan` emits a form spec and
  # `--json add --apply --answers <file>` provisions non-interactively. Both
  # bypass the interactive prompts below (which read stdin and can't run over a
  # non-TTY SSH exec).
  if json_mode; then
    case "${SRVMGR_PHASE:-}" in
      plan)  _add_plan_emit;        return 0;;
      apply) _add_apply_json "$@";  return $?;;
    esac
  fi

  local domain="${1:-}" root="${2:-}"
  local server; server="$(registry_resolve "$OPT_SERVER")"
  ssh_use_server "$server"

  banner "add — server: ${server}"

  # 1. Connectivity + remote layout.
  local who
  who="$(step_capture "Connecting to ${server}" ssh_probe)" \
    || die "Cannot reach server '${server}'. Check 'server servers' / your SSH key."
  step "Preparing ${REMOTE_ETC}" remote_ensure_dirs \
    || die "Could not create ${REMOTE_ETC} (need root or passwordless sudo)."

  # 2. Domain + root.
  section "Site"
  while :; do
    domain="$(ask_required "Domain" "$domain")"
    is_valid_domain "$domain" && break
    warn "That doesn't look like a valid domain."; domain=""
  done
  while :; do
    root="$(ask_required "Root (web directory)" "$root")"
    is_abs_path "$root" && break
    warn "Root must be an absolute path."; root=""
  done

  # Already set up? A registered config or a live nginx vhost means the site is
  # already deployed and serving — offer to adopt it (register/refresh its
  # config, keep its vhost, no deploy) instead of provisioning over the top.
  local registered=0 has_vhost=""
  remote_site_exists "$domain" && registered=1
  has_vhost="$(nginx_vhost_exists "$domain" || true)"
  if [[ "$registered" == 1 || -n "$has_vhost" ]]; then
    if [[ "$registered" == 1 ]]; then
      info "Site '${domain}' is already registered on '${server}'."
    else
      info "Site '${domain}' already has a live nginx vhost on '${server}'."
    fi
    if confirm "Adopt the existing site (register it without deploying or replacing its nginx vhost)?" "Y"; then
      cmd_import "$domain" "$root"
      return $?
    fi
    [[ "$registered" == 1 ]] \
      && die "Site '${domain}' already exists. Use 'server update ${domain}' to deploy."
    warn "Continuing with a fresh setup — this will replace the existing nginx vhost for ${domain}."
    confirm "Proceed?" "n" || die "Aborted."
  fi

  if ! remote_exists "$root"; then
    warn "Path '${root}' does not exist yet on ${server}."
    confirm "Continue anyway?" "n" || die "Aborted."
  fi

  # 3. Auto-discovery.
  section "Auto-discovery"
  local raw
  raw="$(step_capture "Analyzing project" discover_collect "$root")" \
    || die "Discovery failed."
  discover_parse <<<"$raw"   # here-string (not a pipe) so DISC_* land in this shell

  # 4. Confirm detected values; prompt for the rest.
  local fw="$DISC_FRAMEWORK"
  if [[ -n "$fw" ]]; then
    info "Framework detected: ${C_BOLD}$(framework_label "$fw")${C_RESET}"
    confirm "Is that correct?" "Y" || fw="$(_choose_framework)"
  else
    fw="$(_choose_framework)"
  fi

  # Application root. For front-controller PHP frameworks the web root is the
  # project's public/ dir, so the app root (git, composer, artisan, .env) is its
  # parent — never the public dir itself (the .env must NOT be web-served).
  local app_root="${DISC_APP_ROOT:-$root}"
  if _is_laravel_like "$fw" || [[ "$fw" == "symfony" ]]; then
    if [[ "$root" == */public ]]; then
      app_root="${root%/public}"
    elif [[ "$app_root" == "$root" ]]; then
      # The caller gave the application root, not its public/ dir. Keep it as
      # the app root and serve <root>/public as the web root, so the .env and
      # source stay off the web and index.php resolves (otherwise nginx serves
      # the project root → 403 + exposed .env).
      root="$root/public"
    fi
  fi
  is_php_framework "$fw" && info "Application root: ${C_BOLD}${app_root}${C_RESET}"

  # Git
  local git_remote="$DISC_GIT_REMOTE" git_branch="$DISC_GIT_BRANCH"
  if [[ -n "$git_remote" ]]; then
    info "Git remote: ${C_BOLD}${git_remote}${C_RESET}"
    [[ -n "$DISC_GIT_COMMIT" ]] && say "  ${C_GREY}last commit: ${DISC_GIT_COMMIT}${C_RESET}"
    confirm "Use this repository?" "Y" || git_remote="$(ask "Git remote (blank for none)" "")"
    git_branch="$(present "Branch" "${git_branch:-main}")"
  else
    info "No git repository detected in ${app_root}."
    git_remote="$(ask "Git remote URL (blank to skip deploys-from-git)" "")"
    [[ -n "$git_remote" ]] && git_branch="$(ask "Branch" "main")"
  fi

  # PHP — confirm the version, then make sure PHP-FPM for it is actually
  # installed (provisioning it if needed) and resolve its socket.
  local php_version="" php_socket=""
  if is_php_framework "$fw"; then
    php_version="$(present "PHP version" "${DISC_PHP_VERSION:-8.3}")"
    php_socket="$DISC_PHP_SOCKET"
    if [[ -z "$php_socket" ]]; then php_socket="$(php_socket_for "$php_version" || true)"; fi
    if [[ -z "$php_socket" ]]; then
      warn "PHP-FPM ${php_version} does not appear to be installed on ${server}."
      if confirm "Install PHP ${php_version} (FPM + common Laravel extensions + Composer) now?" "Y"; then
        step "Installing PHP ${php_version}" php_install "$php_version" \
          || die "PHP installation failed."
        php_socket="$(php_socket_for "$php_version")"
      fi
    fi
    if [[ -z "$php_socket" ]]; then
      php_socket="$(ask_required "PHP-FPM socket path" "/run/php/php${php_version}-fpm.sock")"
    else
      ok "PHP-FPM socket: ${php_socket}"
    fi
  fi

  # Node package manager
  local node_pm=""
  if is_node_framework "$fw" || [[ -n "$DISC_HAS_PACKAGE" ]]; then
    node_pm="$(present "Node package manager" "${DISC_NODE_PM:-npm}")"
  fi

  # Reverse-proxy upstream (node SSR / explicit proxy)
  local upstream=""
  case "$fw" in
    nodejs|nextjs|nuxt|reverse_proxy)
      upstream="$(ask_required "Upstream to proxy to (host:port)" "127.0.0.1:3000")";;
  esac

  # 5. Database (MariaDB) for Laravel/Statamic.
  DB_REPORT=""
  _add_database "$domain" "$app_root" "$fw"

  # 5b. Scheduler (cron) + background workers (supervisor) for Laravel.
  WORKERS_REPORT=""
  _add_workers "$domain" "$app_root" "$fw" "$php_version"

  # 6. HTTPS
  section "TLS"
  local https=0 le_email=""
  if confirm "Enable HTTPS (Let's Encrypt)?" "Y"; then
    https=1
    le_email="$(ask_required "Let's Encrypt email" "$(global_get le_email)")"
    is_valid_email "$le_email" || warn "That email looks unusual — continuing anyway."
    global_set le_email "$le_email"   # remember for next time
  fi

  # 6. Persist the site config (source of truth, on the server).
  section "Saving configuration"
  local now; now="$(timestamp)"
  step "Writing ${REMOTE_ETC}/sites/${domain}.conf" \
    _add_write_conf "$domain" "$root" "$app_root" "$fw" "$php_version" \
      "$php_socket" "$git_remote" "$git_branch" "$node_pm" "$https" \
      "$le_email" "$upstream" "$now" \
    || die "Failed to write remote config."
  index_set "$domain" "$server"

  # 7. Provision nginx (+ HTTPS).
  section "Provisioning"
  local rendered
  rendered="$(nginx_render "$domain" "$root" "$fw" "$php_socket" "$upstream")"
  step "Installing nginx vhost" _add_install_nginx "$domain" "$rendered" \
    || die "nginx provisioning failed."
  if [[ "$https" == "1" ]]; then
    step "Requesting certificate for ${domain}" nginx_enable_https "$domain" "$le_email" \
      || warn "HTTPS setup failed — the site is live over HTTP. Re-run later with 'server ssl ${domain}'."
  fi

  # 8. Report.
  local proto="http"; [[ "$https" == "1" ]] && proto="https"
  report_box "Site added: ${domain}" \
    "Server      : ${server}" \
    "Framework   : $(framework_label "$fw")" \
    "Web root    : ${root}" \
    "App root    : ${app_root}" \
    "${git_remote:+Repository  : ${git_remote} (${git_branch})}" \
    "${php_version:+PHP         : ${php_version}}" \
    "${DB_REPORT:+Database    : ${DB_REPORT}}" \
    "${DISC_SCHEDULER:+Scheduler   : cron (every minute)}" \
    "${WORKERS_REPORT:+Worker      : ${WORKERS_REPORT} (supervisor)}" \
    "URL         : ${proto}://${domain}" \
    "Next        : server update ${domain}"
}

# _add_database <domain> <app_root> <framework>
#   Provision a MariaDB database (installing the server if needed), generate
#   credentials and write them into the app's .env — creating the .env from a
#   pasted template when the project has none yet. No-op for non-DB frameworks.
_add_database() {
  local domain="$1" app_root="$2" fw="$3"
  _is_laravel_like "$fw" || return 0

  section "Database"
  confirm "Provision a MariaDB database for this site?" "Y" || { info "Skipping database provisioning."; return 0; }

  # Ensure the server is installed and running.
  if db_is_present 2>/dev/null; then
    ok "MariaDB is already installed."
  else
    step "Installing MariaDB" db_install || die "MariaDB installation failed."
  fi

  # Generate credentials (the user never types a DB password).
  local slug; slug="$(slugify "$domain")"
  local db_name="$slug" db_user="$slug" db_pass
  db_pass="$(db_gen_password)"

  step "Creating database '${db_name}' and user '${db_user}'" \
    db_create "$db_name" "$db_user" "$db_pass" || die "Database creation failed."

  # Write credentials into .env (existing, or one the user pastes).
  if db_env_exists "$app_root"; then
    step "Writing credentials to .env" db_set_env_creds "$app_root" "$db_name" "$db_user" "$db_pass" \
      || warn "Could not update .env automatically."
  else
    warn "No .env found at ${app_root}/.env."
    if [[ "${SRVMGR_ASSUME_YES:-0}" == "1" ]]; then
      warn "Non-interactive mode — skipping .env paste. Set DB_* manually."
    else
      say "Paste the project's .env below, then finish with a line containing only: ${C_BOLD}EOF${C_RESET}" >&2
      local content="" line
      while IFS= read -r line; do
        [[ "$line" == "EOF" ]] && break
        content+="$line"$'\n'
      done
      if [[ -n "$content" ]]; then
        step "Creating .env" _add_write_env "$app_root" "$content" || die "Could not write .env."
        step "Writing credentials to .env" db_set_env_creds "$app_root" "$db_name" "$db_user" "$db_pass" \
          || warn "Could not update .env automatically."
      else
        warn "No .env content provided — database created but .env not updated."
      fi
    fi
  fi

  # Surface the generated credentials (shown once; also added to the report).
  ok "Database ready. Credentials (store them safely):"
  say "    DB_DATABASE=${db_name}"
  say "    DB_USERNAME=${db_user}"
  say "    DB_PASSWORD=${db_pass}"
  DB_REPORT="${db_name} / ${db_user} (password set in .env)"

  # Optionally seed the fresh database from a local SQL dump.
  if [[ "${SRVMGR_ASSUME_YES:-0}" != "1" ]] && confirm "Import an existing SQL dump into this database now?" "n"; then
    local dump; dump="$(ask "Path to .sql or .sql.gz file (on this machine)" "")"
    [[ -n "$dump" ]] && _db_do_import "$domain" "$app_root" "$dump" || true
  fi
}

_add_write_env() {
  local app_root="$1" content="$2"
  printf '%s' "$content" | db_write_env "$app_root"
}

# _add_workers <domain> <app_root> <framework> <php_version>
#   Set up the Laravel scheduler cron and (optionally) a queue/Horizon worker.
#   Sets DISC_SCHEDULER/DISC_QUEUE/DISC_HORIZON so the choices persist into the
#   site config (used by 'server update' to restart the right services).
_add_workers() {
  local domain="$1" app_root="$2" fw="$3" ver="$4"
  _is_laravel_like "$fw" || return 0
  section "Scheduler & workers"
  local slug; slug="$(slugify "$domain")"

  if confirm "Set up the Laravel scheduler (runs 'artisan schedule:run' every minute)?" "Y"; then
    if step "Installing scheduler cron" workers_install_scheduler "$slug" "$app_root" "$ver"; then
      DISC_SCHEDULER=1
    else
      warn "Could not install the scheduler cron."
    fi
  fi

  # Decide the worker mode (use detection when available, else ask).
  local mode="none"
  if [[ "$DISC_HORIZON" == "1" ]]; then
    mode="horizon"; info "Horizon detected."
  elif [[ "$DISC_QUEUE" == "1" ]]; then
    mode="queue"; info "Queue usage detected."
  elif [[ "${SRVMGR_ASSUME_YES:-0}" != "1" ]]; then
    say "  Background worker:  1) none   2) queue:work   3) Horizon" >&2
    case "$(ask "Choose" "1")" in
      2) mode="queue";;
      3) mode="horizon";;
      *) mode="none";;
    esac
  fi

  if [[ "$mode" != "none" ]]; then
    step "Ensuring supervisor is installed" workers_ensure_supervisor \
      || warn "supervisor could not be installed — worker not configured."
    if step "Configuring ${mode} worker" workers_install_supervisor "$slug" "$app_root" "$ver" "$mode"; then
      if [[ "$mode" == "horizon" ]]; then DISC_HORIZON=1; else DISC_QUEUE=1; fi
      WORKERS_REPORT="$mode"
    else
      warn "Could not configure the ${mode} worker."
    fi
  fi
}

# Build the conf body and write it remotely. Run as a named helper so it can be
# wrapped by step().
_add_write_conf() {
  local domain="$1" root="$2" app_root="$3" fw="$4" php_version="$5" \
        php_socket="$6" git_remote="$7" git_branch="$8" node_pm="$9" \
        https="${10}" le_email="${11}" upstream="${12}" now="${13}"
  remote_site_write "$domain" <<EOF
domain=$domain
root=$root
app_root=$app_root
framework=$fw
php_version=$php_version
php_socket=$php_socket
git_remote=$git_remote
git_branch=$git_branch
node_pm=$node_pm
https=$https
le_email=$le_email
upstream=$upstream
redis=$DISC_REDIS
queue=$DISC_QUEUE
horizon=$DISC_HORIZON
scheduler=$DISC_SCHEDULER
octane=$DISC_OCTANE
created_at=$now
EOF
}

_add_install_nginx() {
  local domain="$1" rendered="$2"
  printf '%s\n' "$rendered" | nginx_install "$domain"
}

# ---------------------------------------------------------------------------
# JSON two-phase add: plan + apply
# ---------------------------------------------------------------------------

# _add_str_array <item>... -> ["item",...]  (JSON string array)
_add_str_array() {
  local out="[" first=1 a
  for a in "$@"; do
    (( first )) || out+=","
    out+="$(json_str "$a")"
    first=0
  done
  out+="]"
  printf '%s' "$out"
}

# _add_field <id> <type> <label> <value> <required-bool> [options-json] [when-json]
#   -> one encoded plan field object.
_add_field() {
  local o
  o="{$(json_kv_string id "$1"),$(json_kv_string type "$2"),"
  o+="$(json_kv_string label "$3"),$(json_kv_string value "$4"),"
  o+="$(json_kv_raw required "$5")"
  [[ -n "${6:-}" ]] && o+=",$(json_kv_raw options "$6")"
  [[ -n "${7:-}" ]] && o+=",$(json_kv_raw when "$7")"
  o+="}"
  printf '%s' "$o"
}

# _add_plan_emit — emit the `kind:"plan"` form spec a client renders. Static
# (no root known yet, so no discovery): asks for everything up front.
_add_plan_emit() {
  local fw_opts server_opts default_server="" servers_field=""
  fw_opts="$(_add_str_array laravel symfony statamic wordpress static \
    nodejs nextjs nuxt react vue reverse_proxy)"

  # Offer the registered servers as an enum when any exist; otherwise the apply
  # phase falls back to the resolved default.
  read_lines registry_list_names
  if (( ${#READ_LINES[@]} > 0 )); then
    server_opts="$(_add_str_array "${READ_LINES[@]}")"
    default_server="$(registry_default)"
    [[ -n "$default_server" ]] || default_server="${READ_LINES[0]}"
    servers_field="$(_add_field server enum 'Target server' "$default_server" true "$server_opts"),"
  fi

  local tls_when; tls_when="{$(json_kv_string field tls),$(json_kv_string equals true)}"
  local le_email; le_email="$(global_get le_email 2>/dev/null || true)"

  local fields="["
  fields+="$(_add_field domain domain 'Domain name' '' true),"
  fields+="$servers_field"
  fields+="$(_add_field framework enum 'Framework' laravel true "$fw_opts"),"
  fields+="$(_add_field path abspath 'Web root (e.g. /var/www/site/public)' /var/www true),"
  fields+="$(_add_field repo string 'Git repository URL (blank to skip)' '' false),"
  fields+="$(_add_field branch string 'Branch' main false),"
  fields+="$(_add_field php_version string 'PHP version (PHP apps only)' 8.3 false),"
  fields+="$(_add_field tls bool 'Provision HTTPS (Let'\''s Encrypt)' true false),"
  fields+="$(_add_field tls_email string 'Let'\''s Encrypt email' "$le_email" true "" "$tls_when")"
  fields+="]"

  local value; value="{$(json_kv_string command add),$(json_kv_raw fields "$fields")}"
  ui_emit "{\"t\":\"data\",$(json_kv_string kind plan),$(json_kv_raw value "$value")}"
}

# _add_apply_json — provision a site from the uploaded answer bundle, streaming
# the normal section/step/report events. Non-interactive (no prompts). Database
# and worker setup are left to their dedicated commands.
_add_apply_json() {
  local af="${SRVMGR_ANSWERS:-}"
  [[ -n "$af" && -f "$af" ]] || die "Apply phase needs --answers <file>."
  local json; json="$(cat "$af")"

  local domain server fw repo branch root php_version tls tls_email upstream
  domain="$(json_flat_get "$json" domain || true)"
  server="$(json_flat_get "$json" server || true)"
  fw="$(json_flat_get "$json" framework || true)"
  repo="$(json_flat_get "$json" repo || true)"
  branch="$(json_flat_get "$json" branch || true)"; branch="${branch:-main}"
  root="$(json_flat_get "$json" path || true)"
  php_version="$(json_flat_get "$json" php_version || true)"
  php_version="${php_version:-8.3}"
  tls="$(json_flat_get "$json" tls || true)"
  tls_email="$(json_flat_get "$json" tls_email || true)"
  fw="${fw:-static}"

  [[ -n "$domain" ]] || die "A domain is required."
  is_valid_domain "$domain" || die "'${domain}' is not a valid domain."
  [[ -n "$root" ]] || die "A web root is required."
  is_abs_path "$root" || die "Web root must be an absolute path."

  [[ -n "$server" ]] || server="$(registry_resolve "")"
  ssh_use_server "$server"
  banner "add — server: ${server}"
  step_capture "Connecting to ${server}" ssh_probe >/dev/null \
    || die "Cannot reach server '${server}'."
  step "Preparing ${REMOTE_ETC}" remote_ensure_dirs \
    || die "Could not create ${REMOTE_ETC} (need root or passwordless sudo)."

  # Already set up? A registered config or a live nginx vhost means the site is
  # already deployed and serving. Rather than dying (or overwriting it), adopt
  # it non-interactively: register/refresh its config, keep its vhost, no deploy
  # — the headless equivalent of the wizard's adopt path / 'server import'.
  local registered=0 has_vhost="" adopt=0
  remote_site_exists "$domain" && registered=1
  has_vhost="$(nginx_vhost_exists "$domain" || true)"
  [[ "$registered" == 1 || -n "$has_vhost" ]] && adopt=1
  [[ "$adopt" == 1 ]] \
    && info "Site '${domain}' is already set up on '${server}' — adopting it (no deploy, keeping any existing nginx vhost)."

  # Application root: PHP front-controller frameworks serve from public/.
  # Accept the web root either as the public/ dir or as the application root:
  # in the latter case serve <root>/public so the .env and source stay off the
  # web (otherwise nginx serves the project root → 403 + exposed .env).
  local app_root="$root"
  if _is_laravel_like "$fw" || [[ "$fw" == symfony ]]; then
    if [[ "$root" == */public ]]; then
      app_root="${root%/public}"
    else
      root="$root/public"
    fi
  fi

  # PHP-FPM socket (install the runtime if it isn't there yet).
  local php_socket=""
  if is_php_framework "$fw"; then
    php_socket="$(php_socket_for "$php_version" 2>/dev/null || true)"
    if [[ -z "$php_socket" ]]; then
      step "Installing PHP ${php_version}" php_install "$php_version" \
        || warn "PHP ${php_version} install failed — set the socket later."
      php_socket="$(php_socket_for "$php_version" 2>/dev/null || true)"
    fi
    [[ -n "$php_socket" ]] || php_socket="/run/php/php${php_version}-fpm.sock"
  fi

  # Reverse-proxy upstream for node/SSR/proxy sites.
  upstream=""
  case "$fw" in
    nodejs|nextjs|nuxt|reverse_proxy)
      upstream="$(json_flat_get "$json" upstream || true)"
      upstream="${upstream:-127.0.0.1:3000}";;
  esac

  local https=0
  case "$tls" in true|1|yes|Yes|TRUE) https=1;; esac
  # When adopting an existing vhost, reflect reality: read TLS from the vhost
  # instead of the requested flag (we never touch the vhost, so requesting a
  # cert here would be wrong).
  if [[ "$adopt" == 1 && -n "$has_vhost" ]]; then
    https=0
    nginx_vhost_has_tls "$domain" && https=1
  fi
  [[ "$https" == 1 && -n "$tls_email" ]] && global_set le_email "$tls_email"

  # Discovery globals consumed by _add_write_conf — unset in the JSON path.
  DISC_REDIS=""; DISC_QUEUE=""; DISC_HORIZON=""; DISC_SCHEDULER=""; DISC_OCTANE=""

  section "Saving configuration"
  local now; now="$(timestamp)"
  step "Writing ${REMOTE_ETC}/sites/${domain}.conf" \
    _add_write_conf "$domain" "$root" "$app_root" "$fw" "$php_version" \
      "$php_socket" "$repo" "$branch" "" "$https" "$tls_email" "$upstream" "$now" \
    || die "Failed to write remote config."
  index_set "$domain" "$server"

  section "Provisioning"
  if [[ -n "$has_vhost" ]]; then
    info "Existing nginx vhost found — leaving it as-is."
  else
    local rendered
    rendered="$(nginx_render "$domain" "$root" "$fw" "$php_socket" "$upstream")"
    step "Installing nginx vhost" _add_install_nginx "$domain" "$rendered" \
      || die "nginx provisioning failed."
    if [[ "$https" == 1 ]]; then
      step "Requesting certificate for ${domain}" nginx_enable_https "$domain" "$tls_email" \
        || warn "HTTPS setup failed — site is live over HTTP. Re-run 'server ssl ${domain}'."
    fi
  fi

  local proto="http"; [[ "$https" == 1 ]] && proto="https"
  report_box "Site $([[ "$adopt" == 1 ]] && printf adopted || printf added): ${domain}" \
    "Server      : ${server}" \
    "Framework   : $(framework_label "$fw")" \
    "Web root    : ${root}" \
    "App root    : ${app_root}" \
    "${repo:+Repository  : ${repo} (${branch})}" \
    "${php_version:+PHP         : ${php_version}}" \
    "URL         : ${proto}://${domain}" \
    "Next        : server update ${domain}"
}
