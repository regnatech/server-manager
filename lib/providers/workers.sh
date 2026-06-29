# shellcheck shell=bash
#
# workers.sh — provision the Laravel scheduler (cron) and background workers
# (supervisor-managed queue:work or Horizon) on the managed server.
#
# The run user and PHP binary are resolved on the server (owner of the app dir,
# php<version> when present). Requires a server selected via ssh_use_server.

# workers_install_scheduler <slug> <app_root> <php_version>
#   Install a /etc/cron.d entry running `artisan schedule:run` every minute.
workers_install_scheduler() {
  local slug="$1" app_root="$2" ver="$3"
  ssh_script --sudo <<EOF
set -e
app_root=$(shq "$app_root"); ver=$(shq "$ver"); slug=$(shq "$slug")
run_user="\$(stat -c '%U' "\$app_root" 2>/dev/null || echo www-data)"; [ -n "\$run_user" ] || run_user=www-data
php_bin="\$(command -v php\${ver} 2>/dev/null || command -v php 2>/dev/null || echo /usr/bin/php)"
cron=/etc/cron.d/server-manager-\${slug}
cat > "\$cron" <<CRON
# server-manager scheduler for \${slug} — do not edit by hand
* * * * * \${run_user} cd \${app_root} && \${php_bin} artisan schedule:run >> /dev/null 2>&1
CRON
chmod 0644 "\$cron"
echo "scheduler cron installed (user=\${run_user}, php=\${php_bin})"
EOF
}

# workers_ensure_supervisor — install supervisor if it isn't already present.
workers_ensure_supervisor() {
  ssh_sudo '
    set -e
    command -v supervisorctl >/dev/null 2>&1 && exit 0
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y supervisor
      systemctl enable --now supervisor 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y supervisor; systemctl enable --now supervisord 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y supervisor; systemctl enable --now supervisord 2>/dev/null || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache supervisor
    else
      echo "cannot install supervisor automatically" >&2; exit 1
    fi
  '
}

# workers_install_supervisor <slug> <app_root> <php_version> <mode>
#   mode = horizon | queue. Writes a supervisor program and reloads it.
workers_install_supervisor() {
  local slug="$1" app_root="$2" ver="$3" mode="$4"
  ssh_script --sudo <<EOF
set -e
app_root=$(shq "$app_root"); ver=$(shq "$ver"); slug=$(shq "$slug"); mode=$(shq "$mode")
run_user="\$(stat -c '%U' "\$app_root" 2>/dev/null || echo www-data)"; [ -n "\$run_user" ] || run_user=www-data
php_bin="\$(command -v php\${ver} 2>/dev/null || command -v php 2>/dev/null || echo /usr/bin/php)"
mkdir -p /etc/supervisor/conf.d
conf=/etc/supervisor/conf.d/server-manager-\${slug}.conf
if [ "\$mode" = horizon ]; then
  cat > "\$conf" <<SUP
[program:\${slug}-horizon]
process_name=%(program_name)s
command=\${php_bin} \${app_root}/artisan horizon
directory=\${app_root}
user=\${run_user}
autostart=true
autorestart=true
stopwaitsecs=3600
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=\${app_root}/storage/logs/horizon.log
SUP
else
  cat > "\$conf" <<SUP
[program:\${slug}-worker]
process_name=%(program_name)s_%(process_num)02d
command=\${php_bin} \${app_root}/artisan queue:work --sleep=3 --tries=3 --max-time=3600
directory=\${app_root}
user=\${run_user}
numprocs=2
autostart=true
autorestart=true
stopwaitsecs=3600
redirect_stderr=true
stdout_logfile=\${app_root}/storage/logs/worker.log
SUP
fi
chmod 0644 "\$conf"
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true
echo "supervisor \${mode} program installed (user=\${run_user})"
EOF
}
