# shellcheck shell=bash
#
# diff.sh — `server diff <site>`
#
# Pre-deploy preview: fetch origin and show what a deploy WOULD apply — the
# commits between the deployed HEAD and origin/<branch>, and any pending
# database migrations. Read-only (a fetch, no checkout/merge).
#
# JSON: {"t":"data","kind":"deploy_diff","value":{
#         "branch","from","to","ahead":N,"commits":[<git_log items>],
#         "migrations":["2026_..._create_x.php", ...]}}

# _diff_migrations_json <git diff --name-only output> -> JSON array of basenames
_diff_migrations_json() {
  local out="[" first=1 f base
  while IFS= read -r f || [[ -n "$f" ]]; do
    [[ -z "$f" ]] && continue
    base="${f##*/}"
    (( first )) || out+=","
    out+="$(json_str "$base")"; first=0
  done <<<"$1"
  out+="]"
  printf '%s' "$out"
}

cmd_diff() {
  local site="${1:-}"
  [[ -n "$site" ]] || die "Usage: server diff <site>"
  local server; server="$(registry_resolve_for_site "$site" "$OPT_SERVER")"
  ssh_use_server "$server"
  site_load "$site" || die "Site '${site}' is not registered on '${server}'."
  local app_root="$SITE_APP_ROOT" branch="${SITE_GIT_BRANCH:-main}"
  [[ -n "$SITE_GIT_REMOTE" ]] || die "Site '${site}' has no git repository to diff."

  banner "diff — ${site} (${branch})"
  step "Fetching origin" _git_run "$app_root" "git fetch --quiet origin $(shq "$branch")" || warn "fetch failed — comparing against the local ref."

  local range="HEAD..origin/${branch}"
  local raw mig from to ahead
  raw="$(_git_run "$app_root" "git log ${range} --date=short --pretty=format:'%H${_GIT_FS}%h${_GIT_FS}%P${_GIT_FS}%an${_GIT_FS}%ad${_GIT_FS}%ar${_GIT_FS}%d${_GIT_FS}%s' -n 100" 2>/dev/null || true)"
  mig="$(_git_run "$app_root" "git diff --name-only ${range} -- database/migrations 2>/dev/null" || true)"
  from="$(_git_run "$app_root" "git rev-parse --short HEAD 2>/dev/null" || true)"
  to="$(_git_run "$app_root" "git rev-parse --short origin/${branch} 2>/dev/null" || true)"
  ahead="$(printf '%s\n' "$raw" | grep -c . || true)"

  local commits; commits="$(_git_log_json "$raw")"
  local migrations; migrations="$(_diff_migrations_json "$mig")"

  if json_mode; then
    local value="{$(json_kv_string branch "$branch"),$(json_kv_string from "$from"),$(json_kv_string to "$to"),"
    value+="$(json_kv_raw ahead "${ahead:-0}"),$(json_kv_raw commits "$commits"),$(json_kv_raw migrations "$migrations")}"
    ui_emit "{\"t\":\"data\",$(json_kv_string kind deploy_diff),$(json_kv_raw value "$value")}"
    return
  fi

  section "Pending deploy: ${from:-?} → ${to:-?} (${ahead:-0} commit(s))"
  if [[ "${ahead:-0}" == "0" ]]; then
    ok "Already up to date — nothing to deploy."
  else
    printf '%s\n' "$raw" | awk -F"$_GIT_FS" '{printf "  %s %s (%s)\n", $2, $8, $6}' >&2
  fi
  if [[ -n "${mig//[$'\n'[:space:]]/}" ]]; then
    section "Pending migrations"
    printf '%s\n' "$mig" | sed 's#.*/##; s/^/  /' >&2
  fi
}
