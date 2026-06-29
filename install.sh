#!/usr/bin/env bash
#
# install.sh — symlink the `server` CLI onto your PATH. Run from the repo root.
#   ./install.sh            # auto-pick a target bin dir
#   ./install.sh /usr/local/bin
#
# Uninstall: remove the symlink it reports (e.g. rm /usr/local/bin/server).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/bin/server"
[[ -f "$SRC" ]] || { echo "Cannot find $SRC" >&2; exit 1; }
chmod +x "$SRC"

# Choose a target directory: explicit arg, else the first writable candidate.
choose_dir() {
  if [[ -n "${1:-}" ]]; then printf '%s' "$1"; return; fi
  local d
  for d in "/usr/local/bin" "$HOME/.local/bin" "$HOME/bin"; do
    if [[ -d "$d" && -w "$d" ]]; then printf '%s' "$d"; return; fi
  done
  # Prefer a user dir we can create without sudo.
  printf '%s' "$HOME/.local/bin"
}

TARGET_DIR="$(choose_dir "${1:-}")"
mkdir -p "$TARGET_DIR" 2>/dev/null || true
LINK="$TARGET_DIR/server"

if [[ -w "$TARGET_DIR" ]]; then
  ln -sfn "$SRC" "$LINK"
else
  echo "→ $TARGET_DIR is not writable; using sudo."
  sudo ln -sfn "$SRC" "$LINK"
fi

echo "Installed: $LINK -> $SRC"
if ! command -v server >/dev/null 2>&1 || [[ "$(command -v server)" != "$LINK" ]]; then
  case ":$PATH:" in
    *":$TARGET_DIR:"*) ;;
    *) echo "Note: add $TARGET_DIR to your PATH, e.g.:"
       echo "      echo 'export PATH=\"$TARGET_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc";;
  esac
fi
echo "Try:  server help"
