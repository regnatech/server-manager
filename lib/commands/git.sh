# shellcheck shell=bash
#
# git.sh — `server git <log|status|branches|fetch|checkout|pull|push|deploy> <site>`
#
# A small git client for a site's deployed checkout (runs git in the site's
# app_root over SSH). It powers the app's GitKraken-style view and the headline
# "Push & Deploy": `server git push <site> --deploy` pushes the current branch
# and then runs the normal deploy.
#
# Read commands (log/status/branches) emit a JSON data event; action commands
# stream step events. Parsing is split into pure `_git_*_json` builders that are
# unit-tested without a server.

# Field separator for `git log` (unit separator — never appears in content).
_GIT_FS=$'\x1f'

# _git_refs_json <git %d decoration> -> JSON array of refs
# Input looks like:  " (HEAD -> main, origin/main, tag: v1.4)"
_git_refs_json() {
  local d="$1"
  d="${d# }"; d="${d#(}"; d="${d%)}"
  [[ -z "$d" ]] && { printf '[]'; return; }
  local out="[" first=1 r
  local IFS=','
  for r in $d; do
    r="${r#"${r%%[![:space:]]*}"}"; r="${r%"${r##*[![:space:]]}"}"
    [[ -z "$r" ]] && continue
    (( first )) || out+=","
    out+="$(json_str "$r")"; first=0
  done
  out+="]"
  printf '%s' "$out"
}

# _git_log_json <raw log> -> JSON array of commit objects.
# Each raw line: H<FS>h<FS>P<FS>an<FS>ad<FS>ar<FS>d<FS>s
_git_log_json() {
  local raw="$1" items="[" first=1
  local H h P an ad ar d s p parents pf
  while IFS=$_GIT_FS read -r H h P an ad ar d s || [[ -n "$H" ]]; do
    [[ -z "$H" ]] && continue
    parents="["; pf=1
    for p in $P; do (( pf )) || parents+=","; parents+="$(json_str "$p")"; pf=0; done
    parents+="]"
    (( first )) || items+=","
    items+="{$(json_kv_string hash "$H"),$(json_kv_string short "$h"),"
    items+="$(json_kv_raw parents "$parents"),$(json_kv_string author "$an"),"
    items+="$(json_kv_string date "$ad"),$(json_kv_string relative "$ar"),"
    items+="$(json_kv_raw refs "$(_git_refs_json "$d")"),$(json_kv_string subject "$s")}"
    first=0
  done <<<"$raw"
  items+="]"
  printf '%s' "$items"
}

# _git_status_json <branch> <upstream> <ahead> <behind> <porcelain> -> value object
_git_status_json() {
  local branch="$1" upstream="$2" ahead="$3" behind="$4" porcelain="$5"
  local dirty="[" first=1 line path
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    path="${line:3}"
    (( first )) || dirty+=","
    dirty+="$(json_str "$path")"; first=0
  done <<<"$porcelain"
  dirty+="]"
  local clean=true; [[ -n "${porcelain//[$'\n'[:space:]]/}" ]] && clean=false
  printf '{%s,%s,%s,%s,%s,%s}' \
    "$(json_kv_string branch "$branch")" \
    "$(json_kv_string upstream "$upstream")" \
    "$(json_kv_raw ahead "${ahead:-0}")" \
    "$(json_kv_raw behind "${behind:-0}")" \
    "$(json_kv_raw clean "$clean")" \
    "$(json_kv_raw dirty "$dirty")"
}

# _git_branches_json <"name<FS>HEAD" lines> -> JSON array
_git_branches_json() {
  local raw="$1" out="[" first=1 name head remote current
  while IFS=$_GIT_FS read -r name head || [[ -n "$name" ]]; do
    [[ -z "$name" ]] && continue
    current=false; [[ "$head" == "*" ]] && current=true
    remote=false; [[ "$name" == origin/* || "$name" == remotes/* ]] && remote=true
    (( first )) || out+=","
    out+="{$(json_kv_string name "$name"),$(json_kv_raw current "$current"),$(json_kv_raw remote "$remote")}"
    first=0
  done <<<"$raw"
  out+="]"
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
cmd_git() {
  local sub="${1:-}"; [[ $# -gt 0 ]] && shift
  local site="${1:-}"; [[ $# -gt 0 ]] && shift
  [[ -n "$site" ]] || die "Usage: server git <log|status|branches|fetch|checkout|pull|push|deploy> <site> [args]"

  local server; server="$(registry_resolve_for_site "$site" "$OPT_SERVER")"
  ssh_use_server "$server"
  site_load "$site" || die "Site '${site}' is not registered on '${server}'."
  local app_root="$SITE_APP_ROOT"
  [[ -n "$app_root" ]] || die "Site '${site}' has no application root."

  case "$sub" in
    log)      _git_cmd_log "$app_root";;
    status)   _git_cmd_status "$app_root";;
    branches) _git_cmd_branches "$app_root";;
    fetch)    banner "git fetch — ${site}"; step "Fetching origin" _git_run "$app_root" "git fetch --all --prune" || die "fetch failed";;
    checkout) local br="${1:-}"; [[ -n "$br" ]] || die "Usage: server git checkout <site> <branch>"
              banner "git checkout — ${site}"; step "Checking out ${br}" _git_run "$app_root" "git checkout $(shq "$br")" || die "checkout failed";;
    pull)     banner "git pull — ${site}"; step "Pulling ${SITE_GIT_BRANCH:-current}" _git_run "$app_root" "git pull --ff-only" || die "pull failed";;
    push)     _git_cmd_push "$site" "$app_root" "$@";;
    deploy)   _git_cmd_deploy "$site" "$app_root" "${1:-}";;
    branch)   local nb="${1:-}"; [[ -n "$nb" ]] || die "Usage: server git branch <site> <name>"
              banner "git branch — ${site}"
              step "Creating & checking out ${nb}" _git_run "$app_root" "git checkout -b $(shq "$nb")" || die "branch creation failed."
              ok "On new branch '${nb}'.";;
    tag)      local tn="${1:-}" tm="${2:-}"; [[ -n "$tn" ]] || die "Usage: server git tag <site> <name> [message]"
              banner "git tag — ${site}"
              local tagcmd="git tag $(shq "$tn")"; [[ -n "$tm" ]] && tagcmd="git tag -a $(shq "$tn") -m $(shq "$tm")"
              step "Creating tag ${tn}" _git_run "$app_root" "$tagcmd" || die "tag failed."
              step "Pushing tag ${tn}"  _git_run "$app_root" "git push origin $(shq "refs/tags/$tn")" || warn "Tag created locally but push failed.";;
    pr)       _git_cmd_pr "$site" "$app_root" "$@";;
    merge)    _git_cmd_merge "$site" "$app_root" "${1:-}";;
    resolve)  _git_cmd_resolve "$site" "$app_root" "$@";;
    merge-continue) banner "git merge --continue — ${site}"
              step "Completing the merge" _git_run "$app_root" "git commit --no-edit" || die "Could not complete the merge (unresolved conflicts remain?)."
              ok "Merge completed.";;
    merge-abort) banner "git merge --abort — ${site}"
              step "Aborting the merge" _git_run "$app_root" "git merge --abort" || die "Could not abort."
              ok "Merge aborted; working tree restored.";;
    *) die "Unknown git subcommand '${sub}'.";;
  esac
}

# Run a git command in the app root, login user, augmented PATH.
_git_run() { ssh_app_exec "$1" "$2"; }

_git_cmd_log() {
  local app_root="$1" raw
  raw="$(_git_run "$app_root" "git log --date=short --pretty=format:'%H${_GIT_FS}%h${_GIT_FS}%P${_GIT_FS}%an${_GIT_FS}%ad${_GIT_FS}%ar${_GIT_FS}%d${_GIT_FS}%s' -n 50" 2>/dev/null || true)"
  local items; items="$(_git_log_json "$raw")"
  if json_mode; then
    ui_emit "{\"t\":\"data\",$(json_kv_string kind git_log),$(json_kv_raw items "$items")}"
  else
    section "git log — recent commits"
    while IFS= read -r line; do say "  $line"; done < <(printf '%s\n' "$raw" | awk -F"$_GIT_FS" '{printf "%s %s (%s)\n", $2, $8, $6}')
  fi
}

_git_cmd_status() {
  local app_root="$1"
  local branch upstream counts ahead behind porcelain
  branch="$(_git_run "$app_root" "git rev-parse --abbrev-ref HEAD 2>/dev/null" || true)"
  upstream="$(_git_run "$app_root" "git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null" || true)"
  counts="$(_git_run "$app_root" "git rev-list --left-right --count @{u}...HEAD 2>/dev/null" || true)"
  behind="$(printf '%s' "$counts" | awk '{print $1}')"; ahead="$(printf '%s' "$counts" | awk '{print $2}')"
  porcelain="$(_git_run "$app_root" "git status --porcelain 2>/dev/null" || true)"
  local value; value="$(_git_status_json "$branch" "$upstream" "${ahead:-0}" "${behind:-0}" "$porcelain")"
  if json_mode; then
    ui_emit "{\"t\":\"data\",$(json_kv_string kind git_status),$(json_kv_raw value "$value")}"
  else
    section "git status — ${branch}"
    say "  upstream: ${upstream:-none}  (ahead ${ahead:-0}, behind ${behind:-0})"
    [[ -n "${porcelain//[$'\n'[:space:]]/}" ]] && say "  working tree dirty" || ok "working tree clean"
  fi
}

_git_cmd_branches() {
  local app_root="$1" raw
  raw="$(_git_run "$app_root" "git branch -a --format='%(refname:short)${_GIT_FS}%(HEAD)'" 2>/dev/null || true)"
  local items; items="$(_git_branches_json "$raw")"
  if json_mode; then
    ui_emit "{\"t\":\"data\",$(json_kv_string kind git_branches),$(json_kv_raw items "$items")}"
  else
    section "git branches"
    printf '%s\n' "$raw" | awk -F"$_GIT_FS" '{printf "  %s %s\n", ($2=="*"?"*":" "), $1}' >&2
  fi
}

# server git push <site> [--deploy]
_git_cmd_push() {
  local site="$1" app_root="$2"; shift 2
  local deploy=0; [[ "${1:-}" == "--deploy" ]] && deploy=1
  local branch="${SITE_GIT_BRANCH:-HEAD}"
  banner "git push — ${site}"
  step "Pushing ${branch} to origin" _git_run "$app_root" "git push origin HEAD" \
    || die "git push failed."
  if (( deploy )); then
    section "Deploy"
    cmd_update "$site"
  else
    ok "Pushed. Run 'server update ${site}' to deploy."
  fi
}

# server git pr <site> <title> [base] — push the branch and open a GitHub PR
# via the `gh` CLI on the server (must be installed and authenticated there).
_git_cmd_pr() {
  local site="$1" app_root="$2" title="${3:-}" base="${4:-main}"
  [[ -n "$title" ]] || die "Usage: server git pr <site> <title> [base]"
  banner "git pr — ${site}"
  step "Pushing branch to origin" _git_run "$app_root" "git push -u origin HEAD" \
    || die "git push failed."
  local out
  out="$(step_capture "Creating pull request" _git_run "$app_root" \
    "command -v gh >/dev/null 2>&1 || { echo 'NO_GH'; exit 3; }; gh pr create --base $(shq "$base") --title $(shq "$title") --body 'Opened from server-manager' --fill 2>&1")" \
    || die "Could not create the PR. Install and authenticate the GitHub CLI ('gh auth login') on ${site}'s server."
  local url; url="$(printf '%s\n' "$out" | grep -Eo 'https://[^ ]+' | tail -1)"
  if json_mode; then
    ui_emit "{\"t\":\"data\",$(json_kv_string kind pr),$(json_kv_raw value "{$(json_kv_string url "$url"),$(json_kv_string title "$title"),$(json_kv_string base "$base")}")}"
  else
    ok "Pull request created: ${url:-$out}"
  fi
}

# _git_conflict_item_json <path> <ours> <theirs> <conflicted> -> JSON object
_git_conflict_item_json() {
  printf '{%s,%s,%s,%s}' \
    "$(json_kv_string path "$1")" \
    "$(json_kv_string ours "$2")" \
    "$(json_kv_string theirs "$3")" \
    "$(json_kv_string conflicted "$4")"
}

# server git merge <site> <branch>
#   Attempt a merge. On success the working tree advances. On conflicts the
#   merge is LEFT IN PROGRESS and we emit a {"kind":"git_conflicts"} event with,
#   per file, the 'ours' and 'theirs' versions plus the conflicted (markers)
#   content, so the UI can let the user choose or paste a resolution.
_git_cmd_merge() {
  local site="$1" app_root="$2" branch="${3:-}"
  [[ -n "$branch" ]] || die "Usage: server git merge <site> <branch>"
  banner "git merge — ${site} (${branch})"

  local rc=0
  ssh_app_exec "$app_root" "git merge --no-edit $(shq "$branch")" >/dev/null 2>&1 || rc=$?
  if (( rc == 0 )); then
    ok "Merged '${branch}' cleanly."
    json_mode && ui_emit "{\"t\":\"data\",$(json_kv_string kind git_merge),$(json_kv_raw value "{$(json_kv_raw clean true)}")}"
    return 0
  fi

  # Conflicts: gather the unmerged files.
  local files; files="$(ssh_app_exec "$app_root" "git diff --name-only --diff-filter=U" 2>/dev/null || true)"
  if [[ -z "${files//[$'\n'[:space:]]/}" ]]; then
    die "Merge failed (not a conflict — see 'server git status ${site}')."
  fi
  warn "Merge has conflicts — choose a resolution per file, then 'resolve' and 'merge-continue'."

  local items="[" first=1 f ours theirs conflicted
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    ours="$(ssh_app_exec "$app_root" "git show :2:$(shq "$f") 2>/dev/null" || true)"
    theirs="$(ssh_app_exec "$app_root" "git show :3:$(shq "$f") 2>/dev/null" || true)"
    conflicted="$(ssh_app_exec "$app_root" "cat $(shq "$f") 2>/dev/null" || true)"
    (( first )) || items+=","
    items+="$(_git_conflict_item_json "$f" "$ours" "$theirs" "$conflicted")"; first=0
    [[ "$(json_mode; echo $?)" == 0 ]] || warn "  conflict: $f"
  done <<<"$files"
  items+="]"

  if json_mode; then
    ui_emit "{\"t\":\"data\",$(json_kv_string kind git_conflicts),$(json_kv_raw items "$items")}"
  fi
  return 1
}

# server git resolve <site> <path> [--tmp <remote-file>]
#   Apply a resolved version of a conflicted file: copy from <remote-file>
#   (uploaded by the app via SFTP) or read it from stdin (CLI), then `git add`.
_git_cmd_resolve() {
  local site="$1" app_root="$2" path="${3:-}"; shift 3 2>/dev/null || true
  [[ -n "$path" ]] || die "Usage: server git resolve <site> <path> [--tmp <remote-file>]"
  local tmp=""
  [[ "${1:-}" == "--tmp" ]] && tmp="${2:-}"
  banner "git resolve — ${site} (${path})"
  if [[ -n "$tmp" ]]; then
    step "Applying resolved ${path}" ssh_app_exec "$app_root" "cp $(shq "$tmp") $(shq "$path") && rm -f $(shq "$tmp") && git add $(shq "$path")" \
      || die "Could not apply the resolution."
  else
    local content; content="$(cat)"
    step "Applying resolved ${path}" _git_apply_stdin "$app_root" "$path" "$content" \
      || die "Could not apply the resolution."
  fi
  local remaining; remaining="$(ssh_app_exec "$app_root" "git diff --name-only --diff-filter=U | sed '/^$/d' | wc -l" 2>/dev/null || echo '?')"
  ok "Resolved ${path}. Remaining conflicts: ${remaining}."
  json_mode && ui_emit "{\"t\":\"data\",$(json_kv_string kind git_resolved),$(json_kv_raw value "{$(json_kv_string path "$path"),$(json_kv_raw remaining "${remaining:-0}")}")}"
  return 0
}

_git_apply_stdin() {
  local app_root="$1" path="$2" content="$3"
  printf '%s' "$content" | ssh_exec "cd $(shq "$app_root") && cat > $(shq "$path") && git add $(shq "$path")"
}

# server git deploy <site> [branch] — fetch + checkout/pull the branch, then deploy.
_git_cmd_deploy() {
  local site="$1" app_root="$2" branch="${3:-${SITE_GIT_BRANCH:-main}}"
  banner "git deploy — ${site} (${branch})"
  step "Fetching origin"          _git_run "$app_root" "git fetch --all --prune" || die "fetch failed."
  step "Checking out ${branch}"   _git_run "$app_root" "git checkout $(shq "$branch")" || die "checkout failed."
  cmd_update "$site"
}
