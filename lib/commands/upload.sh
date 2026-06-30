# shellcheck shell=bash
#
# upload.sh — `server upload <site> <local_path> <remote_path>`
#
# Push a local file (or directory) to a site's server. The remote path may be
# absolute, or relative to the site's application root. Uploads land in a temp
# location first and are then moved into place with the site's privilege level,
# so root-owned destinations work on sudo servers.

cmd_upload() {
  local site="${1:-}" src="${2:-}" dest="${3:-}"
  [[ -n "$site" && -n "$src" && -n "$dest" ]] \
    || die "Usage: server upload <site> <local_path> <remote_path>"

  # Sanitise the local path: trailing space, surrounding quotes, leading ~.
  src="$(trim "$src")"
  src="${src%\"}"; src="${src#\"}"; src="${src%\'}"; src="${src#\'}"
  src="${src/#\~/$HOME}"
  [[ -e "$src" ]] || die "Local path not found: ${src}"

  local server; server="$(registry_resolve_for_site "$site" "$OPT_SERVER")"
  ssh_use_server "$server"
  site_load "$site" || die "Site '${site}' is not registered on '${server}'."
  local app_root="$SITE_APP_ROOT"
  [[ -n "$app_root" ]] || die "Site '${site}' has no application root."

  # Resolve the destination: absolute as given, else relative to app_root.
  local rpath="$dest"
  [[ "$rpath" == /* ]] || rpath="${app_root%/}/${dest}"
  local parent; parent="$(dirname "$rpath")"

  local is_dir=0; [[ -d "$src" ]] && is_dir=1

  banner "upload — ${site}"
  info "${src} → ${server}:${rpath}"

  local tmp="/tmp/sm-upload-$(timestamp)-$$"
  if (( is_dir )); then
    step "Uploading directory $(basename "$src")" \
      ssh_copy_to "$src" "$tmp" --recursive || die "Upload failed."
  else
    step "Uploading $(basename "$src")" \
      ssh_copy_to "$src" "$tmp" || die "Upload failed."
  fi

  # Move into place with the server's privilege level, creating parent dirs.
  local place
  if (( is_dir )); then
    place="mkdir -p $(shq "$parent") && rm -rf $(shq "$rpath") && cp -a $(shq "$tmp") $(shq "$rpath") && rm -rf $(shq "$tmp")"
  else
    place="mkdir -p $(shq "$parent") && mv -f $(shq "$tmp") $(shq "$rpath")"
  fi
  if ! step "Placing at ${rpath}" ssh_sudo "$place"; then
    ssh_exec "rm -rf $(shq "$tmp")" >/dev/null 2>&1 || true
    die "Could not place the upload at ${rpath} (need root or passwordless sudo?)."
  fi

  ok "Uploaded to ${server}:${rpath}"
  json_mode && ui_emit "{\"t\":\"data\",$(json_kv_string kind upload_done),$(json_kv_raw value "{$(json_kv_string path "$rpath")}")}"
}
