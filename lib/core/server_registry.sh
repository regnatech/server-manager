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

# pick_site — interactively choose a site from the local index; echoes the
# chosen domain on stdout. Returns non-zero if there are no sites.
pick_site() {
  local entries; entries="$(index_all)"
  [[ -n "$entries" ]] || { err "No sites registered yet. Run 'server add' first."; return 1; }
  local domains=() servers=() d s
  while IFS=$'\t' read -r d s || [[ -n "$d" ]]; do
    [[ -z "$d" ]] && continue
    domains+=("$d"); servers+=("$s")
  done <<<"$entries"
  say "  Select a site:" >&2
  local i
  for i in "${!domains[@]}"; do
    printf '    %2d) %s  %s(%s)%s\n' $((i+1)) "${domains[$i]}" "$C_GREY" "${servers[$i]}" "$C_RESET" >&2
  done
  local sel
  while :; do
    sel="$(ask "Number" "1")"
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#domains[@]} )); then
      printf '%s' "${domains[$((sel-1))]}"; return 0
    fi
    warn "Enter a number between 1 and ${#domains[@]}."
  done
}

# _local_keypair — echo the path to a usable local SSH private key, generating
# an ed25519 one if the user has none. (pub key is "<path>.pub")
_local_keypair() {
  local k
  for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
    [[ -f "$k" && -f "$k.pub" ]] && { printf '%s' "$k"; return 0; }
  done
  info "No local SSH key found — generating ~/.ssh/id_ed25519 ..." >&2
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -q >&2 || return 1
  printf '%s' "$HOME/.ssh/id_ed25519"
}

# _connect_auth_fallback <name> <file> <user> <host> <port>
#   Interactively choose how to authenticate when key login failed.
_connect_auth_fallback() {
  local name="$1" file="$2" user="$3" host="$4" port="$5"
  say "" >&2
  say "  How should server-manager authenticate to ${user}@${host}?" >&2
  say "    1) Set up key-based login now (enter the password once) ${C_GREY}[recommended]${C_RESET}" >&2
  say "    2) Use the password for every command ${C_GREY}(stores it locally; needs sshpass)${C_RESET}" >&2
  say "    3) Cancel" >&2
  local choice; choice="$(ask "Choose" "1")"
  case "$choice" in
    1) _connect_setup_key "$file" "$user" "$host" "$port";;
    2) _connect_setup_password "$file";;
    *) info "Cancelled."; return 1;;
  esac
}

# _connect_setup_key <file> <user> <host> <port>
#   Copy the local public key to the server's authorized_keys, prompting for
#   the password once. Switches the record to key auth afterwards.
_connect_setup_key() {
  local file="$1" user="$2" host="$3" port="$4"
  local key; key="$(_local_keypair)" || { err "Could not obtain an SSH key."; return 1; }
  local pub; pub="$(cat "$key.pub")"

  info "Installing your public key on ${user}@${host} — you'll be asked for the password once."
  # ssh reads the password from the TTY; stdin carries the public key.
  if printf '%s\n' "$pub" | ssh -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new \
        -p "$port" "${user}@${host}" \
        'install -d -m 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && k="$(cat)" && grep -qxF "$k" ~/.ssh/authorized_keys || printf "%s\n" "$k" >> ~/.ssh/authorized_keys'; then
    kv_set "$file" auth key
    kv_set "$file" identity_file "$key"
    chmod 600 "$file" 2>/dev/null || true
    ok "Public key installed. Future connections use the key (no password)."
    return 0
  fi
  err "Could not install the key (wrong password, or password login disabled on the server)."
  return 1
}

# _connect_setup_password <file>
#   Store the password and authenticate every command through sshpass.
_connect_setup_password() {
  local file="$1"
  if ! command -v sshpass >/dev/null 2>&1; then
    err "Password mode needs 'sshpass', which isn't installed."
    say "  Install it (e.g. 'apt install sshpass' / 'brew install sshpass') or choose key setup."
    return 1
  fi
  warn "The password will be stored in ${file} (chmod 600). Prefer key setup when possible."
  local pw; pw="$(prompt_secret "SSH password")"
  [[ -n "$pw" ]] || { err "Empty password."; return 1; }
  kv_set "$file" auth password
  kv_set "$file" password "$pw"
  chmod 600 "$file" 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# `server connect <name> user@host[:port] [-i identity] [-p]`
# ---------------------------------------------------------------------------
cmd_server_connect() {
  local name="" target="" identity="" force_password=0
  while (( $# )); do
    case "$1" in
      -i|--identity) identity="$2"; shift 2;;
      -p|--password) force_password=1; shift;;
      -*) die "Unknown option '$1' for 'server connect'.";;
      *)
        if [[ -z "$name" ]]; then name="$1"
        elif [[ -z "$target" ]]; then target="$1"
        else die "Unexpected argument '$1'."; fi
        shift;;
    esac
  done
  [[ -n "$name" && -n "$target" ]] || die "Usage: server connect <name> <user@host[:port]> [-i identity] [-p]"

  config_init_local

  # Parse user@host:port  (default user 'root' if only a host is given)
  local user host port=22
  if [[ "$target" == *@* ]]; then
    user="${target%@*}"; host="${target#*@}"
  else
    user="root"; host="$target"
    info "No user given — assuming 'root'. Use user@host to override."
  fi
  if [[ "$host" == *:* ]]; then
    port="${host##*:}"; host="${host%:*}"
  fi

  local file="$SRVMGR_SERVERS_DIR/${name}.conf"
  kv_set "$file" host "$host"
  kv_set "$file" user "$user"
  kv_set "$file" port "$port"
  kv_set "$file" auth key
  [[ -n "$identity" ]] && kv_set "$file" identity_file "$identity"
  chmod 600 "$file" 2>/dev/null || true

  banner "connect ${name}"

  local who=""
  if [[ "$force_password" == 0 ]]; then
    info "Probing ${user}@${host}:${port} (key-based) ..."
    ssh_use_server "$name"
    who="$(ssh_probe || true)"
  fi

  if [[ -z "$who" ]]; then
    local fb_ok=1
    if [[ "$force_password" == 1 ]]; then
      _connect_setup_password "$file" || fb_ok=0
    else
      warn "Key-based login to ${user}@${host}:${port} didn't work."
      _connect_auth_fallback "$name" "$file" "$user" "$host" "$port" || fb_ok=0
    fi
    if [[ "$fb_ok" == 0 ]]; then
      rm -f "$file"
      return 1
    fi
    ssh_use_server "$name"
    who="$(ssh_probe || true)"
    if [[ -z "$who" ]]; then
      err "Still could not connect to ${user}@${host}:${port}."
      rm -f "$file"
      return 1
    fi
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

# _authorize_self_key <private-key> — append the matching public key to this
# user's authorized_keys so key-based SSH to localhost succeeds. Idempotent.
_authorize_self_key() {
  local key="$1" pub
  pub="$(cat "$key.pub")" || return 1
  install -d -m 700 "$HOME/.ssh" || return 1
  touch "$HOME/.ssh/authorized_keys" || return 1
  chmod 600 "$HOME/.ssh/authorized_keys" || return 1
  grep -qxF "$pub" "$HOME/.ssh/authorized_keys" 2>/dev/null \
    || printf '%s\n' "$pub" >> "$HOME/.ssh/authorized_keys"
}

# ---------------------------------------------------------------------------
# `server connect-self [name]` — register THIS machine as a managed target,
# reachable over SSH at 127.0.0.1. Non-interactive: since we already have shell
# access here, we generate (if needed) and self-authorize an SSH key so key
# login to localhost works under BatchMode. This backs a one-tap
# "Register this server" calls when self-managing a single box.
# ---------------------------------------------------------------------------
cmd_server_connect_self() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name="$(hostname -s 2>/dev/null || true)"
    [[ -n "$name" ]] || name="local"
  fi
  config_init_local

  local user; user="$(id -un)"
  local host="127.0.0.1" port=22

  banner "connect-self ${name}"

  local key
  key="$(_local_keypair)" || die "Could not obtain an SSH key."
  step "Authorizing key for localhost" _authorize_self_key "$key" \
    || die "Could not set up key login to localhost."

  local file="$SRVMGR_SERVERS_DIR/${name}.conf"
  kv_set "$file" host "$host"
  kv_set "$file" user "$user"
  kv_set "$file" port "$port"
  kv_set "$file" auth key
  kv_set "$file" identity_file "$key"
  chmod 600 "$file" 2>/dev/null || true

  ssh_use_server "$name"
  local who; who="$(ssh_probe || true)"
  if [[ -z "$who" ]]; then
    rm -f "$file"
    die "Could not SSH to ${user}@127.0.0.1 — is sshd running and listening on port ${port}?"
  fi
  ok "Connected as ${who}."

  if [[ "$who" == "root" ]]; then
    kv_set "$file" become none
    ok "Login is root — no sudo needed."
  elif ssh_probe_sudo; then
    kv_set "$file" become sudo
    ok "Passwordless sudo available."
  else
    kv_set "$file" become sudo
    warn "Passwordless sudo is NOT available for ${who}; provisioning may fail."
    say "  Grant NOPASSWD sudo (/etc/sudoers.d/${who}: ${who} ALL=(ALL) NOPASSWD:ALL) or run as root."
  fi

  if [[ -z "$(registry_default)" ]]; then
    global_set default_server "$name"
    info "Set '${name}' as the default server."
  fi

  ssh_close
  ok "This server is registered as '${name}'."
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
