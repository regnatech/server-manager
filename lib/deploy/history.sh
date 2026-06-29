# shellcheck shell=bash
#
# history.sh — deploy history on the server, the basis for rollback.
# Layout (remote):
#   /etc/server-manager/sites/<domain>/deploys/<ts>.meta   (key=value)
#   /etc/server-manager/sites/<domain>/current             (-> latest ok ts)
#
# Each .meta records: ts, sha_before, sha_after, backup_path, status, duration.

_history_dir() { printf '%s/%s/deploys' "$REMOTE_SITES" "$1"; }
_history_current() { printf '%s/%s/current' "$REMOTE_SITES" "$1"; }

# history_record <domain> <ts> <sha_before> <sha_after> <backup_path> <status> <duration>
history_record() {
  local domain="$1" ts="$2" sha_before="$3" sha_after="$4" backup="$5" status="$6" dur="$7"
  local dir; dir="$(_history_dir "$domain")"
  local cur; cur="$(_history_current "$domain")"
  ssh_script --sudo <<EOF
set -e
mkdir -p $(shq "$dir")
cat > $(shq "$dir/$ts.meta") <<META
ts=$ts
sha_before=$sha_before
sha_after=$sha_after
backup_path=$backup
status=$status
duration=$dur
META
if [ "$status" = ok ]; then printf '%s' $(shq "$ts") > $(shq "$cur"); fi
EOF
}

# history_list <domain> -> timestamps newest-first
history_list() {
  local dir; dir="$(_history_dir "$1")"
  ssh_exec "ls -1 $(shq "$dir") 2>/dev/null | sed -n 's/\\.meta\$//p' | sort -r"
}

# history_current <domain> -> the current (latest successful) ts (exit 0 if none)
history_current() {
  ssh_exec "cat $(shq "$(_history_current "$1")") 2>/dev/null || true"
}

# history_previous <domain> — the most recent successful deploy *before* the
# current one (the default rollback target).
history_previous() {
  local domain="$1" cur all line prev=""
  cur="$(history_current "$domain")"
  all="$(history_list "$domain")" || return 1
  local seen_cur=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ -n "$cur" && "$line" == "$cur" ]]; then seen_cur=1; continue; fi
    # first ok deploy after we've passed current (older than current)
    if [[ -z "$cur" || "$seen_cur" == 1 ]]; then
      if [[ "$(history_get "$domain" "$line" status)" == "ok" ]]; then prev="$line"; break; fi
    fi
  done <<<"$all"
  printf '%s' "$prev"
}

# history_get <domain> <ts> <key> -> value
history_get() {
  local domain="$1" ts="$2" key="$3"
  local dir; dir="$(_history_dir "$domain")"
  ssh_exec "awk -F= -v k=$(shq "$key") '\$1==k{sub(/^[^=]*=/,\"\");v=\$0} END{print v}' $(shq "$dir/$ts.meta") 2>/dev/null || true"
}
