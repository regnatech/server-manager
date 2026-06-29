# shellcheck shell=bash
#
# server_registry.sh — CRUD over the local server registry plus the logic that
# resolves which server a command targets.
#
# Resolution rules (per the approved design):
#   * --server <name> always wins.
#   * Otherwise the global `default_server` is used.
#   * For site-scoped commands, the server is inferred from sites.index.

# registry_list -> prints server names, one per line (default marked).
registry_list_names() {
  [[ -d "$SRVMGR_SERVERS_DIR" ]] || return 0
  local f
  for f in "$SRVMGR_SERVERS_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    basename "$f" .conf
  done
}

registry_exists() { [[ -f "$SRVMGR_SERVERS_DIR/$1.conf" ]]; }

registry_default() { global_get default_server; }

# registry_resolve <override> — choose a server for a non-site command.
#   <override> is the value of --server (may be empty).
registry_resolve() {
  local override="$1"
  if [[ -n "$override" ]]; then
    registry_exists "$override" || die "Unknown server '${override}'."
    printf '%s' "$override"; return 0
  fi
  local def; def="$(registry_default)"
  if [[ -n "$def" ]] && registry_exists "$def"; then
    printf '%s' "$def"; return 0
  fi
  # Fall back to the sole server if exactly one is registered.
  read_lines registry_list_names
  if (( ${#READ_LINES[@]} == 1 )); then
    printf '%s' "${READ_LINES[0]}"; return 0
  fi
  die "No server selected. Use --server <name>, or 'server use <name>' to set a default."
}

# registry_resolve_for_site <domain> <override> — find the server hosting a
# site. --server wins; otherwise consult the index.
registry_resolve_for_site() {
  local domain="$1" override="$2"
  if [[ -n "$override" ]]; then
    registry_exists "$override" || die "Unknown server '${override}'."
    printf '%s' "$override"; return 0
  fi
  local srv; srv="$(index_get_server "$domain")"
  if [[ -n "$srv" ]] && registry_exists "$srv"; then
    printf '%s' "$srv"; return 0
  fi
  # Unknown site -> fall back to default-server resolution and let the caller
  # verify the site actually exists there.
  registry_resolve "$override"
}

# ---------------------------------------------------------------------------
# `server connect <name> user@host[:port] [-i identity]`
# ---------------------------------------------------------------------------
cmd_server_connect() {
  local name="" target="" identity=""
  while (( $# )); do
    case "$1" in
      -i|--identity) identity="$2"; shift 2;;
      -*) die "Unknown option '$1' for 'server connect'.";;
      *)
        if [[ -z "$name" ]]; then name="$1"
        elif [[ -z "$target" ]]; then target="$1"
        else die "Unexpected argument '$1'."; fi
        shift;;
    esac
  done
  [[ -n "$name" && -n "$target" ]] || die "Usage: server connect <name> <user@host[:port]> [-i identity]"

  config_init_local

  # Parse user@host:port
  local user host port=22
  if [[ "$target" == *@* ]]; then
    user="${target%@*}"; host="${target#*@}"
  else
    die "Target must be in the form user@host (got '${target}')."
  fi
  if [[ "$host" == *:* ]]; then
    port="${host##*:}"; host="${host%:*}"
  fi

  local file="$SRVMGR_SERVERS_DIR/${name}.conf"
  kv_set "$file" host "$host"
  kv_set "$file" user "$user"
  kv_set "$file" port "$port"
  [[ -n "$identity" ]] && kv_set "$file" identity_file "$identity"

  banner "connect ${name}"
  info "Probing ${user}@${host}:${port} ..."
  ssh_use_server "$name"

  local who
  if ! who="$(ssh_probe)"; then
    err "Could not establish an SSH connection to ${user}@${host}:${port}."
    say "  Check the host, your key, and that key-based login is permitted."
    rm -f "$file"
    return 1
  fi
  ok "Connected as ${who}."

  # Determine privilege escalation strategy.
  if [[ "$who" == "root" ]]; then
    kv_set "$file" become none
    ok "Login is root — no sudo needed."
  elif ssh_probe_sudo; then
    kv_set "$file" become sudo
    ok "Passwordless sudo available."
  else
    kv_set "$file" become sudo
    warn "Passwordless sudo is NOT available for ${who}."
    say "  server-manager runs non-interactively and cannot type a sudo password."
    say "  Grant NOPASSWD sudo, e.g. in /etc/sudoers.d/${who}:"
    say "      ${who} ALL=(ALL) NOPASSWD:ALL"
    say "  or connect as root. Provisioning/deploys will fail until then."
  fi

  # First server registered becomes the default.
  if [[ -z "$(registry_default)" ]]; then
    global_set default_server "$name"
    info "Set '${name}' as the default server."
  fi

  ssh_close
  ok "Server '${name}' registered."
}

# ---------------------------------------------------------------------------
# `server use <name>` — set the default server.
# ---------------------------------------------------------------------------
cmd_server_use() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: server use <name>"
  registry_exists "$name" || die "Unknown server '${name}'. Run 'server connect ${name} ...' first."
  global_set default_server "$name"
  ok "Default server is now '${name}'."
}

# ---------------------------------------------------------------------------
# `server servers` — list registered servers.
# ---------------------------------------------------------------------------
cmd_server_servers() {
  config_init_local
  local def; def="$(registry_default)"
  read_lines registry_list_names
  if (( ${#READ_LINES[@]} == 0 )); then
    info "No servers registered yet. Add one with 'server connect <name> user@host'."
    return 0
  fi
  section "Registered servers"
  local n file host user port become marker
  for n in "${READ_LINES[@]}"; do
    file="$SRVMGR_SERVERS_DIR/${n}.conf"
    host="$(kv_get "$file" host)"; user="$(kv_get "$file" user)"
    port="$(kv_get "$file" port)"; become="$(kv_get "$file" become)"
    marker="  "; [[ "$n" == "$def" ]] && marker="${C_GREEN}* ${C_RESET}"
    printf '%b%-14s %s%s@%s:%s%s  %sbecome=%s%s\n' \
      "$marker" "$n" "$C_CYAN" "$user" "$host" "${port:-22}" "$C_RESET" \
      "$C_GREY" "${become:-none}" "$C_RESET" >&2
  done
  say ""
  say "  ${C_GREEN}*${C_RESET} = default (used when --server is omitted)"
}
