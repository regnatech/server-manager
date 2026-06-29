# shellcheck shell=bash
#
# services.sh — restart the runtime services after code/deps change:
# PHP-FPM, supervisor-managed workers, Laravel queue, and Horizon.
#
# Service management needs root, so these run with privilege escalation.

# deploy_restart_php_fpm <php_version>
deploy_restart_php_fpm() {
  local ver="$1"
  ssh_sudo "
    set -e
    restarted=0
    if command -v systemctl >/dev/null 2>&1; then
      for svc in php${ver}-fpm php-fpm php${ver} php-fpm${ver}; do
        if systemctl list-units --type=service --all 2>/dev/null | grep -q \"\${svc}.service\" \
           || systemctl status \"\$svc\" >/dev/null 2>&1; then
          systemctl reload-or-restart \"\$svc\" && { echo \"restarted \$svc\"; restarted=1; break; }
        fi
      done
    fi
    if [ \"\$restarted\" = 0 ]; then
      service php${ver}-fpm restart 2>/dev/null && restarted=1 || true
      [ \"\$restarted\" = 0 ] && service php-fpm restart 2>/dev/null && restarted=1 || true
    fi
    [ \"\$restarted\" = 1 ] || echo 'warn: could not find a php-fpm service to restart' >&2
    true
  "
}

# deploy_restart_supervisor — reread/update programs and restart them.
deploy_restart_supervisor() {
  ssh_sudo "
    if command -v supervisorctl >/dev/null 2>&1; then
      supervisorctl reread >/dev/null 2>&1 || true
      supervisorctl update >/dev/null 2>&1 || true
      supervisorctl restart all >/dev/null 2>&1 || true
      echo 'supervisor programs restarted'
    else
      echo 'supervisor not installed — skipping'
    fi
  "
}

# deploy_queue_restart <app_root> <php_version> — graceful worker reload.
deploy_queue_restart() {
  local app_root="$1" ver="$2"
  ssh_app_exec "$app_root" "$(_php_bin_prelude "$ver") \$PHP artisan queue:restart >/dev/null 2>&1 || true; echo 'queue workers signalled to restart'"
}

# deploy_horizon_terminate <app_root> <php_version> — Horizon restarts itself
# under supervisor after a terminate.
deploy_horizon_terminate() {
  local app_root="$1" ver="$2"
  ssh_app_exec "$app_root" "$(_php_bin_prelude "$ver") \$PHP artisan horizon:terminate >/dev/null 2>&1 || true; echo 'horizon signalled to restart'"
}
