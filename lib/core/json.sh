# shellcheck shell=bash
#
# json.sh — minimal JSON output helpers for the machine-readable (`--json`)
# mode for machine-readable output (see docs/json-protocol.md).
#
# Design: server-manager already funnels every human message through ui.sh.
# When SRVMGR_JSON=1, ui.sh emits one NDJSON event per line on stdout instead
# of pretty TTY text, and the helpers here are the encoder. We deliberately
# avoid any dependency (no jq/python) — a tiny hand-rolled string escaper keeps
# this portable to a bare server.
#
# Event stream contract (one JSON object per line, field "t" discriminates):
#   {"t":"version","contract":"1","version":"0.1.0"}
#   {"t":"banner","label":"..."}
#   {"t":"section","label":"..."}
#   {"t":"step_start","id":"...","label":"..."}
#   {"t":"step_end","id":"...","ok":true,"dur":1.4,"err":"..."}
#   {"t":"log","level":"info|ok|warn|err","msg":"..."}
#   {"t":"progress","cur":3,"total":12,"label":"..."}
#   {"t":"need","id":"..."}          # apply phase needs more answers
#   {"t":"report","title":"...","fields":{"k":"v",...}}
#   {"t":"data","kind":"...","items":[...]}   (or "value":{...})
#   {"t":"done","ok":true}
#
# The contract version is bumped on any breaking change so the UI can refuse a
# mismatched backend at the `version` handshake.

SRVMGR_JSON_CONTRACT="1"

# json_escape <string> -> JSON-escaped string body (no surrounding quotes).
# Handles the characters JSON requires plus control chars; good enough for the
# short labels/paths/messages we emit.
json_escape() {
  local s="$1" out="" i ch code
  local len=${#s}
  for (( i=0; i<len; i++ )); do
    ch="${s:i:1}"
    case "$ch" in
      '"')  out+='\"' ;;
      '\')  out+='\\' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      *)
        printf -v code '%d' "'$ch"
        if (( code < 32 )); then
          out+="$(printf '\\u%04x' "$code")"
        else
          out+="$ch"
        fi
        ;;
    esac
  done
  printf '%s' "$out"
}

# json_str <value> -> a quoted, escaped JSON string.
json_str() { printf '"%s"' "$(json_escape "$1")"; }

# json_kv_string <key> <value> -> "key":"escaped-value"  (string-typed)
json_kv_string() { printf '"%s":"%s"' "$(json_escape "$1")" "$(json_escape "$2")"; }

# json_kv_raw <key> <raw> -> "key":raw   (raw is emitted verbatim: numbers,
# booleans, nested objects/arrays the caller has already encoded)
json_kv_raw() { printf '"%s":%s' "$(json_escape "$1")" "$2"; }

# json_object key1 val1 key2 val2 ...  -> {"key1":"val1",...}
# All values are treated as STRINGS. For non-string fields, build manually with
# json_kv_raw and json_emit_raw.
json_object() {
  local out="{" first=1 k v
  while (( $# >= 2 )); do
    k="$1"; v="$2"; shift 2
    (( first )) || out+=","
    out+="$(json_kv_string "$k" "$v")"
    first=0
  done
  out+="}"
  printf '%s' "$out"
}

# json_emit <pre-encoded-json-object> — print one event line to stdout (the
# data channel the UI reads). Always newline-terminated and flushed per line.
json_emit() {
  printf '%s\n' "$1"
}

# json_event t=<type> [k v]...  — convenience: emit {"t":"<type>", k:"v", ...}
# with all extra fields string-typed. For numeric/bool fields, compose by hand.
json_event() {
  local t="$1"; shift
  local out="{\"t\":$(json_str "$t")" k v
  while (( $# >= 2 )); do
    k="$1"; v="$2"; shift 2
    out+=",$(json_kv_string "$k" "$v")"
  done
  out+="}"
  json_emit "$out"
}

# json_mode — true when the UI/headless JSON protocol is active.
json_mode() { [[ "${SRVMGR_JSON:-0}" == "1" ]]; }

# json_flat_get <json> <key> — read one string value out of a *flat* JSON object
# (the shape the UI uploads as the `add --apply` answer bundle: {"k":"v",...},
# all values string-typed). Prints the decoded value and returns 0 if found,
# else returns 1 with no output. Dependency-free (no jq); handles \" \\ \/ \n \t
# \r \b \f escapes. Not a general JSON parser — only top-level string pairs.
json_flat_get() {
  local json="$1" want="$2"
  local n=${#json} i ch buf="" instr=0 esc=0 expect_key=1 curkey=""
  for (( i=0; i<n; i++ )); do
    ch="${json:i:1}"
    if (( instr )); then
      if (( esc )); then
        case "$ch" in
          n) buf+=$'\n';; t) buf+=$'\t';; r) buf+=$'\r';;
          b) buf+=$'\b';; f) buf+=$'\f';;
          '"') buf+='"';; '\') buf+='\';; '/') buf+='/';;
          *) buf+="$ch";;
        esac
        esc=0
      elif [[ "$ch" == '\' ]]; then
        esc=1
      elif [[ "$ch" == '"' ]]; then
        instr=0
        if (( expect_key )); then
          curkey="$buf"; expect_key=0
        else
          if [[ "$curkey" == "$want" ]]; then printf '%s' "$buf"; return 0; fi
          expect_key=1
        fi
      else
        buf+="$ch"
      fi
    elif [[ "$ch" == '"' ]]; then
      instr=1; buf=""
    fi
  done
  return 1
}
