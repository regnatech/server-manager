# shellcheck shell=bash
#
# db.sh — `server db <import|export> ...`
#
# Load a local .sql/.sql.gz file into a site's database, or dump a site's
# database to a local .sql.gz. The site can be given as an argument or picked
# interactively. Credentials are read from the site's .env on the server — you
# never type them.

cmd_db() {
  local sub="${1:-}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    import) _db_import "$@";;
    export) _db_export "$@";;
    ""|help) _db_usage;;
    *) err "Unknown 'db' subcommand '${sub}'."; _db_usage; return 2;;
  esac
}

_db_usage() {
  cat >&2 <<EOF
Usage:
  server db import [site] [file.sql|file.sql.gz]   Import a SQL dump into a site's DB
  server db export [site] [out.sql.gz]             Dump a site's DB to a local file
If <site> is omitted you'll be asked to pick one.
EOF
}

# server db import [site] [file]
_db_import() {
  local site="" file=""
  if   (( $# >= 2 )); then site="$1"; file="$2"
  elif (( $# == 1 )); then
    if [[ -f "$1" ]]; then file="$1"; else site="$1"; fi
  fi

  [[ -n "$site" ]] || site="$(pick_site)" || return 1
  local server; server="$(registry_resolve_for_site "$site" "$OPT_SERVER")"
  ssh_use_server "$server"

  banner "db import — ${site} @ ${server}"
  site_load "$site" || die "Site '${site}' is not registered on '${server}'."

  [[ -n "$file" ]] || file="$(ask_required "Path to .sql or .sql.gz file (on this machine)")"
  _db_do_import "$site" "$SITE_APP_ROOT" "$file"
}

# _db_do_import <domain> <app_root> <local_file>
#   Shared by the wizard and `server db import`: upload the dump and load it.
_db_do_import() {
  local domain="$1" app_root="$2" localfile="$3"
  # Trim stray whitespace (e.g. a trailing space from paste/tab-completion),
  # strip surrounding quotes, then expand a leading ~.
  localfile="$(trim "$localfile")"
  localfile="${localfile%\"}"; localfile="${localfile#\"}"
  localfile="${localfile%\'}"; localfile="${localfile#\'}"
  localfile="${localfile/#\~/$HOME}"
  [[ -f "$localfile" ]] || { err "File not found: ${localfile}"; return 1; }

  local ext="sql"; case "$localfile" in *.gz) ext="sql.gz";; esac
  local remote="/tmp/srvmgr-import-$(timestamp).${ext}"
  local size; size="$(_human_size "$localfile")"

  warn "This loads SQL into the database of '${domain}'. Existing tables/rows may be overwritten."
  confirm "Import '${localfile}' (${size}) now?" "n" || { info "Cancelled."; return 1; }

  step "Uploading $(basename "$localfile") (${size})" ssh_copy_to "$localfile" "$remote" \
    || { err "Upload failed."; return 1; }
  if step "Importing into database" db_run_import "$app_root" "$remote"; then
    ssh_exec "rm -f $(shq "$remote")" >/dev/null 2>&1 || true
    ok "SQL import complete for ${domain}."
  else
    ssh_exec "rm -f $(shq "$remote")" >/dev/null 2>&1 || true
    err "Import failed — see the output above."
    return 1
  fi
}

# server db export [site] [outfile]
_db_export() {
  local site="" out=""
  if   (( $# >= 2 )); then site="$1"; out="$2"
  elif (( $# == 1 )); then site="$1"
  fi
  [[ -n "$site" ]] || site="$(pick_site)" || return 1

  local server; server="$(registry_resolve_for_site "$site" "$OPT_SERVER")"
  ssh_use_server "$server"
  banner "db export — ${site} @ ${server}"
  site_load "$site" || die "Site '${site}' is not registered on '${server}'."

  [[ -n "$out" ]] || out="./${site}-$(timestamp).sql.gz"
  out="$(trim "$out")"; out="${out/#\~/$HOME}"

  if step "Dumping database to ${out}" _db_export_to_file "$SITE_APP_ROOT" "$out"; then
    ok "Database exported to ${out} ($(_human_size "$out"))."
  else
    rm -f "$out" 2>/dev/null || true
    die "Export failed."
  fi
}

# Stream the remote gzipped dump into a local file.
_db_export_to_file() {
  local app_root="$1" out="$2"
  db_run_export "$app_root" >"$out"
}

# Best-effort human-readable file size (portable across GNU/BSD).
_human_size() {
  local f="$1" b
  b="$(wc -c <"$f" 2>/dev/null | tr -d ' ')" || { printf '?'; return; }
  if   (( b >= 1073741824 )); then LC_ALL=C awk -v b="$b" 'BEGIN{printf "%.1fGB", b/1073741824}'
  elif (( b >= 1048576 ));    then LC_ALL=C awk -v b="$b" 'BEGIN{printf "%.1fMB", b/1048576}'
  elif (( b >= 1024 ));       then LC_ALL=C awk -v b="$b" 'BEGIN{printf "%.1fKB", b/1024}'
  else printf '%dB' "$b"; fi
}
