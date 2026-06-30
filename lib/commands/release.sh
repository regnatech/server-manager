# shellcheck shell=bash
#
# release.sh — `server release <init|deploy|list|rollback|prune> <site>`
#
# Atomic, Envoyer/Capistrano-style releases. Instead of pulling in place, each
# deploy builds a fresh directory and the `current` symlink is flipped to it in
# one atomic step — so a release is never half-applied, and rollback is instant
# (just repoint `current` at the previous release).
#
# Layout under the deploy root D = dirname(app_root):
#   D/releases/<timestamp>/   one checkout per deploy
#   D/shared/                 persisted across releases (.env, storage, ...)
#   D/current -> releases/<ts>  the live symlink (served by nginx)
#
# This is opt-in: `server release init` converts a site to the layout; after
# that `server release deploy` replaces `server update` for that site.
#
# The list/prune SELECTION logic is split into pure helpers for unit testing;
# the remote operations are linted (bash -n) like every other payload.

# Items kept in D/shared and symlinked into each release.
_RELEASE_SHARED=(.env storage)

# _release_list_json <release names, newest-first, one per line> <current name>
_release_list_json() {
  local names="$1" current="$2" out="[" first=1 n cur
  while IFS= read -r n || [[ -n "$n" ]]; do
    [[ -z "$n" ]] && continue
    cur=false; [[ "$n" == "$current" ]] && cur=true
    (( first )) || out+=","
    out+="{$(json_kv_string name "$n"),$(json_kv_raw current "$cur")}"; first=0
  done <<<"$names"
  out+="]"
  printf '%s' "$out"
}

# _release_prune_select <names newest-first> <keep> <current> -> names to remove
# Always keeps the newest <keep> AND the current release, removes the rest.
_release_prune_select() {
  local names="$1" keep="$2" current="$3" i=0 n
  while IFS= read -r n || [[ -n "$n" ]]; do
    [[ -z "$n" ]] && continue
    i=$((i+1))
    (( i <= keep )) && continue
    [[ "$n" == "$current" ]] && continue
    printf '%s\n' "$n"
  done <<<"$names"
}

# Resolve the deploy root (dir that holds releases/, shared/, current).
_release_root() { printf '%s' "$(dirname "${SITE_APP_ROOT%/}")"; }

cmd_release() {
  local sub="${1:-list}"; [[ $# -gt 0 ]] && shift
  local site="${1:-}"; [[ $# -gt 0 ]] && shift
  [[ -n "$site" ]] || die "Usage: server release <init|deploy|list|rollback|prune> <site>"

  local server; server="$(registry_resolve_for_site "$site" "$OPT_SERVER")"
  ssh_use_server "$server"
  site_load "$site" || die "Site '${site}' is not registered on '${server}'."

  case "$sub" in
    init)     _release_init "$site";;
    deploy)   _release_deploy "$site";;
    list)     _release_list "$site";;
    rollback) _release_rollback "$site" "${1:-}";;
    prune)    _release_prune "$site" "${1:-5}";;
    *) die "Unknown release subcommand '${sub}'.";;
  esac
}

# Newest-first release dir names.
_release_names() {
  local root; root="$(_release_root)"
  ssh_exec "ls -1 $(shq "$root/releases") 2>/dev/null | sort -r"
}
_release_current() {
  local root; root="$(_release_root)"
  ssh_exec "readlink $(shq "$root/current") 2>/dev/null | sed 's#.*/##'"
}

_release_list() {
  local names current; names="$(_release_names)"; current="$(_release_current)"
  if json_mode; then
    ui_emit "{\"t\":\"data\",$(json_kv_string kind releases),$(json_kv_raw value "{$(json_kv_string current "$current"),$(json_kv_raw items "$(_release_list_json "$names" "$current")")}")}"
    return
  fi
  section "Releases — ${SITE_DOMAIN}"
  if [[ -z "${names//[$'\n'[:space:]]/}" ]]; then
    info "No releases yet (run 'server release init ${SITE_DOMAIN}')."
    return
  fi
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    [[ "$n" == "$current" ]] && ok "${n}  (current)" || say "  ${n}"
  done <<<"$names"
}

# Convert an in-place site to the releases layout (one-time).
_release_init() {
  local site="$1" root; root="$(_release_root)"
  banner "release init — ${site}"
  warn "This converts ${SITE_APP_ROOT} to an atomic-releases layout under ${root}."
  confirm "Proceed?" "n" || die "Aborted."
  local ts; ts="$(timestamp)"
  step "Setting up ${root}/releases, shared, current" ssh_script --sudo <<EOF
set -e
root=$(shq "$root"); app=$(shq "$SITE_APP_ROOT"); ts=$(shq "$ts")
mkdir -p "\$root/releases/\$ts" "\$root/shared"
# Move the existing checkout into the first release.
cp -a "\$app/." "\$root/releases/\$ts/" 2>/dev/null || true
# Persist shared paths.
for s in ${_RELEASE_SHARED[*]}; do
  if [ -e "\$root/releases/\$ts/\$s" ]; then mv "\$root/releases/\$ts/\$s" "\$root/shared/\$s" 2>/dev/null || true; fi
  ln -sfn "\$root/shared/\$s" "\$root/releases/\$ts/\$s"
done
ln -sfn "\$root/releases/\$ts" "\$root/current"
echo "initialised release \$ts"
EOF
  ok "Initialised. Point the site's app root at ${root}/current and use 'server release deploy ${site}'."
}

# Build a fresh release and atomically switch to it.
_release_deploy() {
  local site="$1" root; root="$(_release_root)"
  local branch="${SITE_GIT_BRANCH:-main}" ts; ts="$(timestamp)"
  local rel="$root/releases/$ts"
  banner "release deploy — ${site} (${branch})"

  [[ -n "$SITE_GIT_REMOTE" ]] || die "Atomic releases need a git remote."
  local auth_remote; auth_remote="$(_deploy_git_auth_url "$SITE_GIT_REMOTE")"
  step "Creating release ${ts}" ssh_script <<EOF
set -e
root=$(shq "$root"); rel=$(shq "$rel"); remote=$(shq "$SITE_GIT_REMOTE"); auth=$(shq "$auth_remote"); branch=$(shq "$branch")
git clone --depth 1 --branch "\$branch" "\$auth" "\$rel"
[ "\$auth" = "\$remote" ] || git -C "\$rel" remote set-url origin "\$remote"
for s in ${_RELEASE_SHARED[*]}; do rm -rf "\$rel/\$s"; ln -sfn "\$root/shared/\$s" "\$rel/\$s"; done
EOF

  # Reuse the normal build steps, pointed at the new release dir.
  _deploy_try "Installing Composer dependencies" _diagnose_composer -- deploy_composer "$rel" \
    || die "composer install failed."
  _deploy_try "Building frontend${SITE_NODE_PM:+ (${SITE_NODE_PM})}" _diagnose_node -- deploy_node "$rel" "$SITE_NODE_PM" || die "Frontend build failed."
  if _is_laravel_like "$SITE_FRAMEWORK"; then
    step "Running migrations" deploy_laravel_migrate "$rel" "$SITE_PHP_VERSION" || die "Migrations failed."
  elif [[ "$SITE_FRAMEWORK" == symfony ]]; then
    step "Running migrations" deploy_symfony_migrate "$rel" "$SITE_PHP_VERSION" || die "Migrations failed."
    step "Warming cache" deploy_symfony_cache "$rel" "$SITE_PHP_VERSION" || warn "Cache warmup reported a problem."
  fi

  step "Switching 'current' → ${ts}" ssh_exec "ln -sfn $(shq "$rel") $(shq "$root/current")" || die "Atomic switch failed."
  step "Reloading services" deploy_restart_php_fpm "$SITE_PHP_VERSION" || warn "PHP-FPM reload reported a problem."
  ok "Released ${ts} (atomic). Roll back instantly with 'server release rollback ${site}'."
  notify_send success "Released ${site}" "Atomic release ${ts}" || true
  if json_mode; then ui_emit "{\"t\":\"data\",$(json_kv_string kind release_done),$(json_kv_raw value "{$(json_kv_string release "$ts")}")}"; fi
}

# Instant rollback: repoint `current` to the previous (or named) release.
_release_rollback() {
  local site="$1" target="${2:-}" root; root="$(_release_root)"
  local names current; names="$(_release_names)"; current="$(_release_current)"
  if [[ -z "$target" ]]; then
    # the first release older than current
    target="$(printf '%s\n' "$names" | awk -v c="$current" 'f{print;exit} $0==c{f=1}')"
  fi
  [[ -n "$target" ]] || die "No previous release to roll back to."
  banner "release rollback — ${site} → ${target}"
  step "Switching 'current' → ${target}" ssh_exec "test -d $(shq "$root/releases/$target") && ln -sfn $(shq "$root/releases/$target") $(shq "$root/current")" \
    || die "Rollback failed (release '${target}' not found?)."
  step "Reloading services" deploy_restart_php_fpm "$SITE_PHP_VERSION" || warn "PHP-FPM reload reported a problem."
  ok "Rolled back to ${target} (instant)."
}

# Remove old releases, keeping the newest N and the current one.
_release_prune() {
  local site="$1" keep="${2:-5}" root; root="$(_release_root)"
  local names current remove; names="$(_release_names)"; current="$(_release_current)"
  remove="$(_release_prune_select "$names" "$keep" "$current")"
  if [[ -z "${remove//[$'\n'[:space:]]/}" ]]; then ok "Nothing to prune (keeping ${keep})."; return; fi
  banner "release prune — ${site} (keep ${keep})"
  local n
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    step "Removing ${n}" ssh_exec "rm -rf $(shq "$root/releases/$n")" || warn "Could not remove ${n}."
  done <<<"$remove"
  ok "Pruned old releases."
}
