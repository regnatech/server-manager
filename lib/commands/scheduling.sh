# shellcheck shell=bash
#
# scheduling.sh — manage the Laravel scheduler, background workers and custom
# cron jobs of a site:
#   server scheduler <site> [status|on|off]
#   server worker    <site> [status|setup|restart|logs]
#   server cron      <site> [list|add "<sched>" "<cmd>"|remove <n>]

# Resolve site -> server, load config. Echoes nothing; sets SITE_* + uses the
# selected server. Shared preamble for the commands below.
_sched_prepare() {
  local site="$1"
  [[ -n "$site" ]] || return 1
  local server; server="$(registry_resolve_for_site "$site" "$OPT_SERVER")"
  ssh_use_server "$server"
  site_load "$site" || die "Site '${site}' is not registered on '${server}'."
  _SCHED_SERVER="$server"
}

# ---------------------------------------------------------------------------
# server scheduler <site> [status|on|off]
# ---------------------------------------------------------------------------
cmd_scheduler() {
  local site="${1:-}" action="${2:-status}"
  [[ -n "$site" ]] || site="$(pick_site)" || return 1
  _sched_prepare "$site"
  local slug; slug="$(slugify "$site")"
  case "$action" in
    status)
      section "Scheduler — ${site}"
      workers_scheduler_status "$slug" | sed 's/^/  /' >&2;;
    on|setup|enable)
      step "Installing scheduler cron" workers_install_scheduler "$slug" "$SITE_APP_ROOT" "$SITE_PHP_VERSION" \
        && _sched_persist "$site" scheduler 1 && ok "Scheduler enabled (runs every minute)." \
        || die "Could not enable the scheduler.";;
    off|disable)
      step "Removing scheduler cron" workers_scheduler_remove "$slug" \
        && _sched_persist "$site" scheduler 0 && ok "Scheduler disabled." \
        || die "Could not disable the scheduler.";;
    *) die "Usage: server scheduler <site> [status|on|off]";;
  esac
}

# ---------------------------------------------------------------------------
# server worker <site> [status|setup|restart|logs]
# ---------------------------------------------------------------------------
cmd_worker() {
  local site="${1:-}" action="${2:-status}"
  [[ -n "$site" ]] || site="$(pick_site)" || return 1
  _sched_prepare "$site"
  local slug; slug="$(slugify "$site")"
  case "$action" in
    status)
      section "Workers — ${site}"
      workers_status "$slug" | sed 's/^/  /' >&2;;
    setup|enable)
      local mode="queue"; [[ "$SITE_HORIZON" == "1" ]] && mode="horizon"
      if [[ "$SITE_HORIZON" != "1" && "$SITE_QUEUE" != "1" ]]; then
        say "  Worker type:  1) queue:work   2) Horizon" >&2
        case "$(ask "Choose" "1")" in 2) mode="horizon";; *) mode="queue";; esac
      fi
      step "Ensuring supervisor" workers_ensure_supervisor || warn "supervisor unavailable."
      step "Configuring ${mode} worker" workers_install_supervisor "$slug" "$SITE_APP_ROOT" "$SITE_PHP_VERSION" "$mode" \
        && { [[ "$mode" == horizon ]] && _sched_persist "$site" horizon 1 || _sched_persist "$site" queue 1; } \
        && ok "Worker (${mode}) configured." || die "Could not configure the worker.";;
    restart)
      step "Restarting workers" workers_restart "$slug" || die "Could not restart workers.";;
    remove|off|disable)
      step "Removing worker" workers_remove "$slug" \
        && _sched_persist "$site" horizon 0 && _sched_persist "$site" queue 0 \
        && ok "Worker removed." || die "Could not remove the worker.";;
    logs)
      cmd_logs "$site" queue;;
    *) die "Usage: server worker <site> [status|setup|restart|logs|remove]";;
  esac
}

# ---------------------------------------------------------------------------
# server cron <site> [list|add "<schedule>" "<command>"|remove <n>]
# ---------------------------------------------------------------------------
cmd_cron() {
  local site="${1:-}" action="${2:-list}"
  [[ -n "$site" ]] || { site="$(pick_site)" || return 1; action="${1:-list}"; }
  _sched_prepare "$site"
  local slug; slug="$(slugify "$site")"
  case "$action" in
    list)
      section "Cron — ${site}"
      workers_cron_list "$slug" "$SITE_APP_ROOT" | sed 's/^/  /' >&2;;
    add)
      local schedule="${3:-}" command="${4:-}"
      [[ -n "$schedule" ]] || schedule="$(ask_required "Schedule (cron expression, e.g. '0 3 * * *')")"
      [[ -n "$command" ]]  || command="$(ask_required "Command to run")"
      step "Adding cron job" workers_cron_add "$slug" "$schedule" "$command" "$SITE_APP_ROOT" \
        && ok "Cron job added." || die "Could not add cron job.";;
    remove|rm)
      local n="${3:-}"
      [[ -n "$n" ]] || { workers_cron_list "$slug" "$SITE_APP_ROOT" | sed 's/^/  /' >&2; n="$(ask_required "Custom cron job number to remove")"; }
      step "Removing cron job #${n}" workers_cron_remove "$slug" "$n" \
        && ok "Cron job removed." || die "Could not remove cron job.";;
    *) die "Usage: server cron <site> [list|add \"<schedule>\" \"<command>\"|remove <n>]";;
  esac
}

# Persist a boolean flag (scheduler/queue/horizon) into the remote site conf.
_sched_persist() {
  local site="$1" key="$2" val="$3"
  remote_site_load "$site" \
    | awk -v k="$key" -v v="$val" '
        $0 ~ "^"k"=" {print k"="v; seen=1; next}
        {print}
        END{if(!seen) print k"="v}' \
    | remote_site_write "$site"
}
