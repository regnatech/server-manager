# shellcheck shell=bash
#
# metrics.sh — `server metrics [server|site]`
#
# A quick health snapshot of a server: CPU, memory, disk, load, uptime and the
# status of the core services. In --json mode it emits a single
# {"t":"data","kind":"metrics","value":{...}} event the desktop app renders as
# gauges; otherwise a TTY report.
#
# The parsing of /proc, free and df output is split into pure `_metrics_eval_*`
# helpers so it can be unit-tested without a live server.

# Services we report on (php*-fpm variants are collapsed to the first active).
_METRICS_SERVICES=(nginx php8.3-fpm php8.2-fpm php8.1-fpm php-fpm mysql mariadb redis-server redis supervisor)

# _metrics_eval_load <"/proc/loadavg" line> -> "l1 l5 l15"
_metrics_eval_load() {
  printf '%s\n' "$1" | awk '{print $1, $2, $3}'
}

# _metrics_eval_mem <"free -b" output> -> "used total pct"
_metrics_eval_mem() {
  printf '%s\n' "$1" | awk '/^Mem:/ {
    total=$2; used=$3;
    pct=(total>0)?int(used*100/total):0;
    print used, total, pct; found=1
  } END { if (!found) print 0, 0, 0 }'
}

# _metrics_eval_disk <"df -P -B1 <mount>" output> -> "used total pct"
_metrics_eval_disk() {
  printf '%s\n' "$1" | awk 'NR==2 {
    total=$2; used=$3;
    pct=(total>0)?int(used*100/total):0;
    print used, total, pct; found=1
  } END { if (!found) print 0, 0, 0 }'
}

# _metrics_eval_uptime <"/proc/uptime" line> -> integer seconds
_metrics_eval_uptime() {
  printf '%s\n' "$1" | awk '{print int($1)}'
}

cmd_metrics() {
  local scope="${1:-}" server
  if [[ -n "$scope" ]]; then
    server="$(registry_resolve_for_site "$scope" "$OPT_SERVER" 2>/dev/null || registry_resolve "$OPT_SERVER")"
  else
    server="$(registry_resolve "$OPT_SERVER")"
  fi
  ssh_use_server "$server"

  banner "metrics — ${server}"
  section "Health snapshot"

  local raw
  raw="$(step_capture "Reading load, CPU, memory & disk" _metrics_gather)" \
    || die "Could not read metrics from '${server}'."

  # Slice the marker-delimited sections.
  local load cpus uptime mem disk cpupct services_raw
  load="$(_metrics_section "$raw" LOAD)"
  cpus="$(_metrics_section "$raw" CPUS)"
  uptime="$(_metrics_section "$raw" UPTIME)"
  mem="$(_metrics_section "$raw" MEM)"
  disk="$(_metrics_section "$raw" DISK)"
  cpupct="$(_metrics_section "$raw" CPUPCT)"
  services_raw="$(_metrics_section "$raw" SERVICES)"

  read -r l1 l5 l15 <<<"$(_metrics_eval_load "$load")"
  read -r mem_used mem_total mem_pct <<<"$(_metrics_eval_mem "$mem")"
  read -r disk_used disk_total disk_pct <<<"$(_metrics_eval_disk "$disk")"
  local up_s; up_s="$(_metrics_eval_uptime "$uptime")"
  cpus="${cpus:-1}"; cpupct="${cpupct:-0}"

  # Build the services JSON array (dedupe php*-fpm to the first active one).
  local services_json="[" first=1 name state seen_php=0
  while read -r name state; do
    [[ -z "$name" ]] && continue
    [[ "$state" == "unknown" ]] && continue
    if [[ "$name" == php*-fpm || "$name" == php-fpm ]]; then
      [[ "$seen_php" == 1 ]] && continue
      [[ "$state" == "active" ]] && seen_php=1
    fi
    local active=false; [[ "$state" == "active" ]] && active=true
    (( first )) || services_json+=","
    services_json+="{$(json_kv_string name "$name"),$(json_kv_raw active "$active")}"
    first=0
  done <<<"$services_raw"
  services_json+="]"

  if json_mode; then
    local host="$_SSH_HOST"
    local value="{$(json_kv_string server "$server"),$(json_kv_string host "$host"),"
    value+="$(json_kv_raw uptime_seconds "${up_s:-0}"),"
    value+="$(json_kv_raw load "[${l1:-0},${l5:-0},${l15:-0}]"),"
    value+="$(json_kv_raw cpu_count "${cpus}"),$(json_kv_raw cpu_pct "${cpupct}"),"
    value+="$(json_kv_raw mem "{$(json_kv_raw used "${mem_used:-0}"),$(json_kv_raw total "${mem_total:-0}"),$(json_kv_raw pct "${mem_pct:-0}")}"),"
    value+="$(json_kv_raw disk "{$(json_kv_raw used "${disk_used:-0}"),$(json_kv_raw total "${disk_total:-0}"),$(json_kv_raw pct "${disk_pct:-0}")}"),"
    value+="$(json_kv_raw services "$services_json")}"
    ui_emit "{\"t\":\"data\",$(json_kv_string kind metrics),$(json_kv_raw value "$value")}"
    return
  fi

  report_box "Health: ${server}" \
    "CPU      : ${cpupct}% of ${cpus} core(s)" \
    "Memory   : ${mem_pct}% ($(_metrics_human "${mem_used:-0}") / $(_metrics_human "${mem_total:-0}"))" \
    "Disk /   : ${disk_pct}% ($(_metrics_human "${disk_used:-0}") / $(_metrics_human "${disk_total:-0}"))" \
    "Load     : ${l1} ${l5} ${l15}" \
    "Uptime   : $(_metrics_uptime_human "${up_s:-0}")"
  say ""
  while read -r name state; do
    [[ -z "$name" || "$state" == "unknown" ]] && continue
    [[ "$state" == "active" ]] && ok "${name} active" || warn "${name} ${state}"
  done <<<"$services_raw"
}

# Remote gather: print marker-delimited raw sources for local parsing.
_metrics_gather() {
  ssh_exec '
    echo "###LOAD";   cat /proc/loadavg 2>/dev/null
    echo "###CPUS";   nproc 2>/dev/null || echo 1
    echo "###UPTIME"; cat /proc/uptime 2>/dev/null
    echo "###MEM";    free -b 2>/dev/null
    echo "###DISK";   df -P -B1 / 2>/dev/null
    echo "###CPUPCT"; { read -r _ u n s i w r1 r2 r3 r4 </proc/stat; t1=$((u+n+s+i+w)); idle1=$i; sleep 0.3; read -r _ u n s i w r1 r2 r3 r4 </proc/stat; t2=$((u+n+s+i+w)); idle2=$i; dt=$((t2-t1)); di=$((idle2-idle1)); if [ "$dt" -gt 0 ]; then echo $(( (100*(dt-di))/dt )); else echo 0; fi; }
    echo "###SERVICES"
    for s in nginx php8.3-fpm php8.2-fpm php8.1-fpm php-fpm mysql mariadb redis-server redis supervisor; do
      printf "%s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null || echo unknown)"
    done
    echo "###END"
  '
}

# _metrics_section <raw> <NAME> — print lines between ###NAME and the next ###.
_metrics_section() {
  printf '%s\n' "$1" | awk -v m="###$2" '
    $0==m {grab=1; next}
    /^###/ {grab=0}
    grab {print}'
}

# _metrics_human <bytes> -> human readable (e.g. 2.1 GB)
_metrics_human() {
  awk -v b="${1:-0}" 'BEGIN{
    split("B KB MB GB TB PB", u, " "); i=1;
    while (b>=1024 && i<6){b/=1024; i++}
    printf (i==1?"%d %s":"%.1f %s"), b, u[i]
  }'
}

# _metrics_uptime_human <seconds> -> "14d 6h 3m"
_metrics_uptime_human() {
  awk -v s="${1:-0}" 'BEGIN{
    d=int(s/86400); s-=d*86400; h=int(s/3600); s-=h*3600; m=int(s/60);
    out="";
    if(d>0) out=out d "d ";
    if(h>0||d>0) out=out h "h ";
    out=out m "m";
    print out
  }'
}
