# shellcheck shell=bash
#
# import.sh — `server import <domain> <root>`
# Adopt a site that is already deployed and serving: auto-discover it, persist
# the config, and register it — WITHOUT running a deploy. An existing nginx
# vhost is left untouched (you are only adopting it); one is offered only if
# none is found.

cmd_import() {
  local domain="${1:-}" root="${2:-}"
  [[ -n "$domain" && -n "$root" ]] || die "Usage: server import <domain> <root> [--server <name>]"
  is_valid_domain "$domain" || die "'${domain}' is not a valid domain."
  is_abs_path "$root" || die "Root must be an absolute path."

  local server; server="$(registry_resolve "$OPT_SERVER")"
  ssh_use_server "$server"

  banner "import — ${domain} @ ${server}"
  step "Preparing ${REMOTE_ETC}" remote_ensure_dirs || die "Could not create ${REMOTE_ETC}."

  if remote_site_exists "$domain"; then
    confirm "Site '${domain}' already exists on '${server}'. Overwrite its config?" "n" || die "Aborted."
  fi
  remote_exists "$root" || die "Path '${root}' does not exist on ${server}."

  # Discover.
  section "Auto-discovery"
  local raw
  raw="$(step_capture "Analyzing ${root}" discover_collect "$root")" || die "Discovery failed."
  discover_parse <<<"$raw"   # here-string (not a pipe) so DISC_* land in this shell

  local fw="${DISC_FRAMEWORK:-static}"
  local app_root="${DISC_APP_ROOT:-$root}"
  info "Detected: ${C_BOLD}$(framework_label "$fw")${C_RESET}"
  [[ -n "$DISC_GIT_REMOTE" ]] && say "  repo   : ${DISC_GIT_REMOTE} (${DISC_GIT_BRANCH:-?})"
  [[ -n "$DISC_PHP_VERSION" ]] && say "  php    : ${DISC_PHP_VERSION} (${DISC_PHP_SOCKET:-no socket})"

  # Detect an existing nginx vhost + whether TLS is already configured.
  local has_vhost https=0
  has_vhost="$(nginx_vhost_exists "$domain" || true)"
  if [[ -n "$has_vhost" ]]; then
    info "Existing nginx vhost found — leaving it as-is."
    nginx_vhost_has_tls "$domain" && https=1
  fi

  # Persist config (reuse the add helper).
  section "Saving configuration"
  local now; now="$(timestamp)"
  step "Writing ${REMOTE_ETC}/sites/${domain}.conf" \
    _add_write_conf "$domain" "$root" "$app_root" "$fw" "$DISC_PHP_VERSION" \
      "$DISC_PHP_SOCKET" "$DISC_GIT_REMOTE" "${DISC_GIT_BRANCH:-main}" "$DISC_NODE_PM" \
      "$https" "$(global_get le_email)" "" "$now" \
    || die "Failed to write remote config."
  index_set "$domain" "$server"

  # Offer to create a vhost only when none exists.
  if [[ -z "$has_vhost" ]]; then
    if confirm "No nginx vhost found. Create one now?" "Y"; then
      local upstream=""
      case "$fw" in nodejs|nextjs|nuxt|reverse_proxy) upstream="$(ask_required "Upstream (host:port)" "127.0.0.1:3000")";; esac
      local rendered; rendered="$(nginx_render "$domain" "$root" "$fw" "$DISC_PHP_SOCKET" "$upstream")"
      step "Installing nginx vhost" _add_install_nginx "$domain" "$rendered" || warn "nginx provisioning failed."
    fi
  fi

  report_box "Site imported: ${domain}" \
    "Server      : ${server}" \
    "Framework   : $(framework_label "$fw")" \
    "Web root    : ${root}" \
    "${DISC_GIT_REMOTE:+Repository  : ${DISC_GIT_REMOTE}}" \
    "Next        : server update ${domain}"
}
