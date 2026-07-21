# shellcheck shell=bash
#
# nginx.sh — render an nginx vhost from a template and install it on the
# selected server. Handles both Debian-style sites-available/sites-enabled and
# RHEL-style conf.d layouts. TLS is delegated to certbot --nginx, which rewrites
# the vhost in place to add the 443 server + HTTP->HTTPS redirect.
#
# Requires a server selected via ssh_use_server.

# nginx_template_for <framework> -> absolute template path
nginx_template_for() {
  local fw="$1" name
  case "$fw" in
    laravel|symfony|statamic) name="laravel.conf.tpl";;
    wordpress)                name="wordpress.conf.tpl";;
    static|react|vue)         name="static.conf.tpl";;
    nodejs|nextjs|nuxt|reverse_proxy) name="proxy.conf.tpl";;
    *)                        name="static.conf.tpl";;
  esac
  printf '%s/nginx/%s' "$SRVMGR_TEMPLATES" "$name"
}

# nginx_render <domain> <root> <framework> <php_socket> <upstream> -> stdout
# Pure local string substitution (no sed delimiter pitfalls with paths).
nginx_render() {
  local domain="$1" root="$2" fw="$3" socket="$4" upstream="$5"
  local tpl; tpl="$(nginx_template_for "$fw")"
  [[ -f "$tpl" ]] || die "nginx template not found: $tpl"
  local content; content="$(cat "$tpl")"
  content="${content//\{\{DOMAIN\}\}/$domain}"
  content="${content//\{\{ROOT\}\}/$root}"
  content="${content//\{\{FRAMEWORK\}\}/$(framework_label "$fw")}"
  content="${content//\{\{PHP_SOCKET\}\}/$socket}"
  content="${content//\{\{UPSTREAM\}\}/$upstream}"
  printf '%s\n' "$content"
}

# nginx_install <domain> < rendered-config
#   Writes the vhost remotely, enables it, validates, and reloads nginx. The
#   rendered config is read on the control side and embedded into the remote
#   script (the script is the remote's stdin, so the config can't be streamed).
nginx_install() {
  local domain="$1"
  local body; body="$(cat)"
  ssh_script --sudo <<EOF
set -e
domain=$(shq "$domain")
write_to() {
  cat > "\$1" <<'SRVMGR_PAYLOAD_EOF'
${body}
SRVMGR_PAYLOAD_EOF
  chmod 0644 "\$1"
}

if [ -d /etc/nginx/sites-available ]; then
  avail="/etc/nginx/sites-available/\$domain"
  write_to "\$avail"
  ln -sfn "\$avail" "/etc/nginx/sites-enabled/\$domain"
else
  # RHEL/Alpine style: single conf.d file is both source and enabled.
  write_to "/etc/nginx/conf.d/\$domain.conf"
fi

# Validate before reloading; never leave nginx in a broken state.
if ! nginx -t; then
  echo "nginx config test failed for \$domain" >&2
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl reload nginx
else
  nginx -s reload
fi
EOF
}

# nginx_vhost_exists <domain> — echo "yes" (and exit 0) when a vhost for the
#   domain is already present, in either the Debian or RHEL/Alpine layout.
#   Empty output + non-zero when none is found. Used to detect a site that is
#   already served so we adopt it instead of overwriting it.
nginx_vhost_exists() {
  local domain="$1"
  ssh_exec "for f in /etc/nginx/sites-available/${domain} /etc/nginx/sites-enabled/${domain} /etc/nginx/conf.d/${domain}.conf; do [ -f \"\$f\" ] && { echo yes; exit 0; }; done; exit 1"
}

# nginx_vhost_has_tls <domain> — exit 0 when the existing vhost already
#   references a certificate (so HTTPS is configured), non-zero otherwise.
nginx_vhost_has_tls() {
  local domain="$1"
  ssh_exec "grep -rqs 'ssl_certificate' /etc/nginx/sites-available/${domain} /etc/nginx/conf.d/${domain}.conf 2>/dev/null"
}

# nginx_enable_https <domain> <le_email>
#   Obtain/renew a Let's Encrypt cert and let certbot patch the vhost.
nginx_enable_https() {
  local domain="$1" email="$2"
  ssh_sudo "command -v certbot >/dev/null 2>&1 || { echo 'certbot is not installed on the server (try: apt install certbot python3-certbot-nginx)'; exit 1; }; \
certbot --nginx -n --agree-tos --redirect -m $(shq "$email") -d $(shq "$domain")"
}

# nginx_remove <domain> — disable a site and reload (used by future teardown).
nginx_remove() {
  local domain="$1"
  ssh_sudo "rm -f /etc/nginx/sites-enabled/$domain /etc/nginx/sites-available/$domain /etc/nginx/conf.d/$domain.conf; nginx -t && { systemctl reload nginx 2>/dev/null || nginx -s reload; }"
}
