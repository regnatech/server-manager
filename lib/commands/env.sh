# shellcheck shell=bash
#
# env.sh — `server env <site> [action]` : manage a site's remote .env.
#
#   server env <site>                 Show the .env (alias: list | show)
#   server env <site> get <KEY>       Print one value
#   server env <site> set <KEY> <V>   Set/replace a key in place (adds if absent)
#   server env <site> unset <KEY>     Remove a key
#   server env <site> pull [file]     Download the .env to a local file
#   server env <site> push <file>     Replace the remote .env with a local file
#   server env <site> edit            Open the .env in $EDITOR, save back remotely
#
# Edits are written atomically on the server, preserving the file's other lines.
# Values are written verbatim — quote values containing spaces yourself, e.g.
#   server env set my.site APP_NAME '"My App"'

# _env_file <app_root> -> the remote .env path.
_env_file() { printf '%s/.env' "${1%/}"; }

# env_get_all <app_root> — print the whole .env (empty if it doesn't exist).
env_get_all() { ssh_exec "cat $(shq "$(_env_file "$1")") 2>/dev/null || true"; }

# env_get_key <app_root> <key> — print a single value (no quotes/whitespace).
env_get_key() {
  local app_root="$1" key="$2"
  ssh_exec "grep -E ^$(shq "$key")= $(shq "$(_env_file "$app_root")") 2>/dev/null | head -1 | cut -d= -f2-"
}

# env_set_key <app_root> <key> <value> — set/replace a key in place, appending
# it when absent. Creates the .env if it doesn't exist yet.
env_set_key() {
  local app_root="$1" key="$2" value="$3"
  ssh_script <<EOF
set -e
envf=$(shq "$(_env_file "$app_root")")
k=$(shq "$key"); v=$(shq "$value")
[ -f "\$envf" ] || { mkdir -p $(shq "${app_root%/}"); : > "\$envf"; chmod 0640 "\$envf"; }
tmp="\$(mktemp)"
awk -v k="\$k" -v v="\$v" '
  \$0 ~ "^"k"=" && !done { print k"="v; done=1; next }
  { print }
  END{ if(!done) print k"="v }
' "\$envf" > "\$tmp"
chmod 0640 "\$tmp"
mv "\$tmp" "\$envf"
echo "set \$k"
EOF
}

# env_unset_key <app_root> <key> — drop a key from the .env.
env_unset_key() {
  local app_root="$1" key="$2"
  ssh_script <<EOF
set -e
envf=$(shq "$(_env_file "$app_root")")
k=$(shq "$key")
[ -f "\$envf" ] || { echo "no .env" >&2; exit 1; }
tmp="\$(mktemp)"
awk -v k="\$k" '\$0 ~ "^"k"=" {next} {print}' "\$envf" > "\$tmp"
chmod 0640 "\$tmp"
mv "\$tmp" "\$envf"
echo "unset \$k"
EOF
}

cmd_env() {
  local site="${1:-}"; [[ $# -gt 0 ]] && shift
  [[ -n "$site" ]] || die "Usage: server env <site> [show|get <K>|set <K> <V>|unset <K>|pull [file]|push <file>|edit]"
  local sub="${1:-show}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    show|list|get|set|unset|pull|push|edit) :;;
    *) die "Unknown env action '${sub}'. Try: show | get | set | unset | pull | push | edit";;
  esac

  local server; server="$(registry_resolve_for_site "$site" "$OPT_SERVER")"
  ssh_use_server "$server"
  site_load "$site" || die "Site '${site}' is not registered on '${server}'."
  local app_root="$SITE_APP_ROOT"
  [[ -n "$app_root" ]] || die "Site '${site}' has no application root."

  case "$sub" in
    show|list)
      local content; content="$(env_get_all "$app_root")"
      if json_mode; then
        ui_emit "{\"t\":\"data\",$(json_kv_string kind env),$(json_kv_raw value "{$(json_kv_string content "$content")}")}"
      else
        [[ -n "$content" ]] || { info "No .env at $(_env_file "$app_root") (or it's empty)."; return 0; }
        printf '%s\n' "$content"
      fi
      ;;
    get)
      local key="${1:-}"; [[ -n "$key" ]] || die "Usage: server env get <site> <KEY>"
      env_get_key "$app_root" "$key"
      ;;
    set)
      local key="${1:-}" value="${2:-}"
      [[ -n "$key" ]] || die "Usage: server env set <site> <KEY> <VALUE>"
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid key '${key}' (use letters, digits, underscore)."
      banner "env set — ${site}"
      step "Setting ${key}" env_set_key "$app_root" "$key" "$value" || die "Could not update the .env."
      ok "${key} saved to ${server}:$(_env_file "$app_root")."
      ;;
    unset)
      local key="${1:-}"; [[ -n "$key" ]] || die "Usage: server env unset <site> <KEY>"
      banner "env unset — ${site}"
      step "Removing ${key}" env_unset_key "$app_root" "$key" || die "Could not update the .env."
      ok "${key} removed from ${server}:$(_env_file "$app_root")."
      ;;
    pull)
      local out="${1:-}"; [[ -n "$out" ]] || out="./${site}.env"
      out="${out/#\~/$HOME}"
      env_get_all "$app_root" > "$out" || die "Could not download the .env."
      [[ -s "$out" ]] || warn "Downloaded file is empty (no remote .env?)."
      ok "Saved ${server}'s .env to ${out}."
      ;;
    push)
      local in="${1:-}"; [[ -n "$in" ]] || die "Usage: server env push <site> <localfile>"
      in="$(trim "$in")"; in="${in/#\~/$HOME}"
      [[ -f "$in" ]] || die "Local file not found: ${in}"
      banner "env push — ${site}"
      step "Uploading .env" _env_push_file "$app_root" "$in" \
        || die "Could not write the remote .env."
      ok "Replaced ${server}:$(_env_file "$app_root")."
      ;;
    edit)
      json_mode && die "'env edit' is interactive; use get/set or pull/push in --json mode."
      _env_edit "$site" "$app_root" "$server"
      ;;
  esac
}

# _env_push_file <app_root> <localfile> — feed a local file into db_write_env.
_env_push_file() { db_write_env "$1" < "$2"; }

# _env_edit <site> <app_root> <server> — download, open $EDITOR, push back.
_env_edit() {
  local site="$1" app_root="$2" server="$3"
  local editor="${VISUAL:-${EDITOR:-vi}}"
  local tmp; tmp="$(mktemp -t "sm-env-${site}.XXXXXX")" || die "Could not create a temp file."
  env_get_all "$app_root" > "$tmp"
  local before; before="$(cksum < "$tmp")"
  "$editor" "$tmp" || { rm -f "$tmp"; die "Editor exited with an error."; }
  local after; after="$(cksum < "$tmp")"
  if [[ "$before" == "$after" ]]; then
    rm -f "$tmp"; info "No changes — .env left untouched."; return 0
  fi
  banner "env edit — ${site}"
  step "Saving .env to ${server}" _env_push_file "$app_root" "$tmp" || { rm -f "$tmp"; die "Could not save the .env."; }
  rm -f "$tmp"
  ok "Saved ${server}:$(_env_file "$app_root")."
}
