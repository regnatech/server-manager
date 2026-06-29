#!/usr/bin/env bash
#
# tests/docker/smoke.sh — end-to-end integration test against a disposable
# container that plays the role of a managed server. Requires Docker.
#
#   bash tests/docker/smoke.sh
#
# It builds the image, boots it, registers it with `server connect`, imports
# the bundled static site, provisions nginx, and asserts the site serves 200.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SERVER="$ROOT/bin/server"

NAME="srvmgr-smoke"
PORT=2222
KEY="$HERE/id_test"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Generating throwaway SSH key"
rm -f "$KEY" "$KEY.pub"
ssh-keygen -t ed25519 -N '' -f "$KEY" -q

echo "==> Building image"
docker build -t "$NAME" "$HERE" >/dev/null

echo "==> Starting container"
docker run -d --name "$NAME" -p "$PORT:22" -p "8088:80" "$NAME" >/dev/null
sleep 3

# Isolate config to a scratch dir so the test never touches real state.
export SRVMGR_HOME="$(mktemp -d)"
export SRVMGR_ASSUME_YES=1
export SSH_CM_DIR="$SRVMGR_HOME/cm"; mkdir -p "$SSH_CM_DIR"

echo "==> server connect"
"$SERVER" connect smoke "deploy@127.0.0.1:$PORT" -i "$KEY"

echo "==> server import demo.local /var/www/demo"
"$SERVER" import demo.local /var/www/demo --server smoke

echo "==> server list"
"$SERVER" list

echo "==> HTTP check"
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: demo.local' http://127.0.0.1:8088/)"
echo "    HTTP $code"
[[ "$code" == "200" ]] || { echo "SMOKE FAIL: expected 200"; exit 1; }

echo "==> SMOKE PASSED"
