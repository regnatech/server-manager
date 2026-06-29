# shellcheck shell=bash
#
# ssl.sh — `server ssl <site>`
# Issue or renew the Let's Encrypt certificate for a site and flip it to HTTPS.

cmd_ssl() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || die "Usage: server ssl <site> [--server <name>]"

  local server; server="$(registry_resolve_for_site "$domain" "$OPT_SERVER")"
  ssh_use_server "$server"

  banner "ssl — ${domain} @ ${server}"
  site_load "$domain" || die "Site '${domain}' is not registered on '${server}'."

  local email="$SITE_LE_EMAIL"
  if [[ -z "$email" ]]; then
    email="$(ask_required "Let's Encrypt email" "$(global_get le_email)")"
    global_set le_email "$email"
  fi

  step "Requesting/renewing certificate for ${domain}" nginx_enable_https "$domain" "$email" \
    || die "certbot failed. Ensure DNS points here and certbot+nginx plugin are installed."

  # Persist https=1 / email on the site config.
  if [[ "$SITE_HTTPS" != "1" || "$SITE_LE_EMAIL" != "$email" ]]; then
    step "Updating site configuration" _ssl_persist "$domain" "$email" || warn "Could not update site config."
  fi
  ok "HTTPS is active: https://${domain}"
}

# Rewrite the site conf with https=1 and the email (preserving everything else).
_ssl_persist() {
  local domain="$1" email="$2"
  local raw; raw="$(remote_site_load "$domain")"
  printf '%s\n' "$raw" \
    | awk -v e="$email" '
        /^https=/   {print "https=1"; h=1; next}
        /^le_email=/{print "le_email=" e; m=1; next}
        {print}
        END {if(!h) print "https=1"; if(!m) print "le_email=" e}' \
    | remote_site_write "$domain"
}
