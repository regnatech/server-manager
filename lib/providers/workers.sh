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

# workers_recommend_procs — print "REC CORES MEMMB": a recommended worker
# process count for the selected server plus the inputs behind it. Heuristic:
# one worker per CPU core, capped by ~256 MB of RAM each (using 60% of total),
# floored at 1.
workers_recommend_procs() {
  ssh_exec '
    cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    memkb=$(awk "/^MemTotal/{print \$2; exit}" /proc/meminfo 2>/dev/null || echo 1048576)
    memmb=$((memkb/1024))
    by_mem=$(( (memmb*60/100) / 256 )); [ "$by_mem" -lt 1 ] && by_mem=1
    rec=$cores; [ "$by_mem" -lt "$rec" ] && rec=$by_mem; [ "$rec" -lt 1 ] && rec=1
    printf "%s %s %s\n" "$rec" "$cores" "$memmb"
  '
}

# workers_install_supervisor <slug> <app_root> <php_version> <mode> [procs]
#   mode = horizon | queue | messenger. [procs] sets numprocs for queue/messenger
#   (default 2); Horizon runs a single supervisor and manages its own pool.
workers_install_supervisor() {
  local slug="$1" app_root="$2" ver="$3" mode="$4" procs="${5:-}"
  [[ "$procs" =~ ^[0-9]+$ ]] && (( procs >= 1 )) || procs=2
  ssh_script --sudo <<EOF
set -e
app_root=$(shq "$app_root"); ver=$(shq "$ver"); slug=$(shq "$slug"); mode=$(shq "$mode"); procs=$(shq "$procs")
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
elif [ "\$mode" = messenger ]; then
  mkdir -p "\${app_root}/var/log" 2>/dev/null || true
  cat > "\$conf" <<SUP
[program:\${slug}-messenger]
process_name=%(program_name)s_%(process_num)02d
command=\${php_bin} \${app_root}/bin/console messenger:consume async --time-limit=3600 --memory-limit=256M
directory=\${app_root}
user=\${run_user}
numprocs=\${procs}
autostart=true
autorestart=true
stopwaitsecs=3600
redirect_stderr=true
stdout_logfile=\${app_root}/var/log/messenger.log
SUP
else
  cat > "\$conf" <<SUP
[program:\${slug}-worker]
process_name=%(program_name)s_%(process_num)02d
command=\${php_bin} \${app_root}/artisan queue:work --sleep=3 --tries=3 --max-time=3600
directory=\${app_root}
user=\${run_user}
numprocs=\${procs}
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

# ---------------------------------------------------------------------------
# Inspection / management (used by the worker / scheduler / cron commands).
# ---------------------------------------------------------------------------

# workers_status <slug> — supervisorctl status of this site's programs.
workers_status() {
  local slug="$1"
  ssh_sudo "
    command -v supervisorctl >/dev/null 2>&1 || { echo 'supervisor is not installed'; exit 0; }
    out=\$(supervisorctl status 2>/dev/null | grep -E \"^$slug-(worker|horizon|messenger)\" || true)
    [ -n \"\$out\" ] && echo \"\$out\" || echo 'no worker configured for this site'
  "
}

# workers_restart <slug> — restart this site's supervisor programs.
workers_restart() {
  local slug="$1"
  ssh_sudo "
    command -v supervisorctl >/dev/null 2>&1 || { echo 'supervisor not installed' >&2; exit 1; }
    progs=\$(supervisorctl status 2>/dev/null | grep -oE \"^$slug-(worker|horizon|messenger)[^ ]*\" | sed 's/:.*//' | sort -u)
    [ -n \"\$progs\" ] || { echo 'no worker configured for this site' >&2; exit 1; }
    for p in \$progs; do supervisorctl restart \"\$p\" >/dev/null 2>&1 || true; done
    echo \"restarted: \$(echo \$progs | tr '\n' ' ')\"
  "
}

# workers_remove <slug> — stop and delete this site's supervisor program.
workers_remove() {
  local slug="$1"
  ssh_sudo "
    conf=/etc/supervisor/conf.d/server-manager-$slug.conf
    if command -v supervisorctl >/dev/null 2>&1; then
      supervisorctl stop \"$slug-worker:*\" >/dev/null 2>&1 || true
      supervisorctl stop \"$slug-messenger:*\" >/dev/null 2>&1 || true
      supervisorctl stop \"$slug-horizon\" >/dev/null 2>&1 || true
    fi
    rm -f \"\$conf\"
    supervisorctl reread >/dev/null 2>&1 || true
    supervisorctl update >/dev/null 2>&1 || true
    echo 'worker removed'
  "
}

# workers_scheduler_status <slug> — show the scheduler cron entry, if present.
workers_scheduler_status() {
  local slug="$1"
  ssh_sudo "f=/etc/cron.d/server-manager-$slug; if [ -f \"\$f\" ]; then grep -v '^#' \"\$f\" | grep -v '^[[:space:]]*\$'; else echo 'scheduler not installed'; fi"
}

# workers_scheduler_remove <slug>
workers_scheduler_remove() {
  local slug="$1"
  ssh_sudo "rm -f /etc/cron.d/server-manager-$slug && echo 'scheduler cron removed'"
}

# workers_cron_list <slug> <app_root> — list all server-manager cron entries for
# the site plus the run user's personal crontab.
workers_cron_list() {
  local slug="$1" app_root="$2"
  ssh_sudo "
    app_root=$(shq "$app_root")
    run_user=\$(stat -c '%U' \"\$app_root\" 2>/dev/null || echo www-data)
    for f in /etc/cron.d/server-manager-$slug /etc/cron.d/server-manager-$slug-custom; do
      if [ -f \"\$f\" ]; then echo \"# \$f\"; grep -v '^[[:space:]]*\$' \"\$f\"; echo; fi
    done
    echo \"# crontab for \$run_user\"
    crontab -l -u \"\$run_user\" 2>/dev/null | grep -v '^[[:space:]]*\$' || echo '(empty)'
  "
}

# workers_cron_add <slug> <schedule> <command> <app_root>
#   Append a custom cron line (run as the app owner) to a managed cron.d file.
workers_cron_add() {
  local slug="$1" schedule="$2" command="$3" app_root="$4"
  ssh_script --sudo <<EOF
set -e
app_root=$(shq "$app_root"); slug=$(shq "$slug")
schedule=$(shq "$schedule"); cmd=$(shq "$command")
run_user="\$(stat -c '%U' "\$app_root" 2>/dev/null || echo www-data)"; [ -n "\$run_user" ] || run_user=www-data
f=/etc/cron.d/server-manager-\${slug}-custom
[ -f "\$f" ] || printf '# server-manager custom cron for %s\n' "\$slug" > "\$f"
printf '%s %s %s\n' "\$schedule" "\$run_user" "\$cmd" >> "\$f"
chmod 0644 "\$f"
echo "added: \$schedule \$run_user \$cmd"
EOF
}

# workers_cron_remove <slug> <n> — remove the n-th custom cron job (1-based).
workers_cron_remove() {
  local slug="$1" n="$2"
  ssh_script --sudo <<EOF
set -e
slug=$(shq "$slug"); n=$(shq "$n")
f=/etc/cron.d/server-manager-\${slug}-custom
[ -f "\$f" ] || { echo "no custom cron jobs" >&2; exit 1; }
awk -v n="\$n" 'BEGIN{c=0} /^#/{print;next} /^[[:space:]]*\$/{print;next} {c++; if(c==n) next; print}' "\$f" > "\$f.tmp"
mv "\$f.tmp" "\$f"
echo "removed custom cron job #\$n"
EOF
}

