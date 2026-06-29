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
  if remote_site_exists "$domain"; then
    die "Site '${domain}' already exists on '${server}'. Use 'server update ${domain}' or 'server import'."
  fi
  while :; do
    root="$(ask_required "Root (web directory)" "$root")"
    is_abs_path "$root" && break
    warn "Root must be an absolute path."; root=""
  done
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

  local app_root="${DISC_APP_ROOT:-$root}"

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

  # PHP
  local php_version="" php_socket=""
  if is_php_framework "$fw"; then
    php_version="$(present "PHP version" "${DISC_PHP_VERSION}")"
    if [[ -n "$DISC_PHP_SOCKET" ]]; then
      php_socket="$(present "PHP-FPM socket" "$DISC_PHP_SOCKET")"
    else
      warn "Could not find a php-fpm socket automatically."
      php_socket="$(ask_required "PHP-FPM socket path" "/run/php/php${php_version}-fpm.sock")"
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
}

_add_write_env() {
  local app_root="$1" content="$2"
  printf '%s' "$content" | db_write_env "$app_root"
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
