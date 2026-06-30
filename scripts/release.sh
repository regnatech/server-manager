#!/usr/bin/env bash
#
# release.sh — cut a release in one command.
#
#   make release VERSION=X.Y.Z
#
# Bumps the version, runs the tests, tags + pushes, creates the GitHub release,
# computes the release tarball's sha256, writes it into the Homebrew formula, and
# publishes the formula to the tap (regnatech/homebrew-tap).
#
# Requires: a clean working tree on the repo, `gh` (authenticated), perl, curl.

set -euo pipefail

REPO="regnatech/server-manager"
TAP="regnatech/homebrew-tap"
FORMULA="packaging/homebrew/server-manager.rb"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "Usage: make release VERSION=X.Y.Z" >&2; exit 1; }
TAG="v${VERSION}"

command -v gh   >/dev/null || { echo "gh (GitHub CLI) is required." >&2; exit 1; }
command -v perl >/dev/null || { echo "perl is required." >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] \
  || { echo "Working tree is not clean — commit or stash first." >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 \
  && { echo "Tag $TAG already exists." >&2; exit 1; } || true

echo "==> Tests"
make test >/dev/null

echo "==> Bumping version to $VERSION"
perl -i -pe "s/^SRVMGR_VERSION=.*/SRVMGR_VERSION=\"$VERSION\"/" bin/server
perl -i -pe "s|archive/refs/tags/v[0-9.]+\.tar\.gz|archive/refs/tags/$TAG.tar.gz|" "$FORMULA"
perl -i -pe "s/assert_match \"[0-9.]+\"/assert_match \"$VERSION\"/" "$FORMULA"

echo "==> Commit + tag + push"
git add bin/server "$FORMULA"
git commit -q -m "release $TAG"
git tag -a "$TAG" -m "server-manager $TAG"
git push -q origin HEAD
git push -q origin "$TAG"

echo "==> Computing release tarball sha256"
url="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
tmp="$(mktemp)"
sha=""
for _ in 1 2 3 4 5 6; do
  if curl -fsSL "$url" -o "$tmp"; then
    sha="$(shasum -a 256 "$tmp" | awk '{print $1}')"; break
  fi
  sleep 3
done
rm -f "$tmp"
[[ -n "$sha" ]] || { echo "Could not download $url to compute sha256." >&2; exit 1; }
echo "    sha256=$sha"

echo "==> Writing sha256 into the formula"
perl -i -pe "s/sha256 \"[0-9a-f]*\"/sha256 \"$sha\"/" "$FORMULA"
git add "$FORMULA"
git commit -q -m "homebrew: $TAG"
git push -q origin HEAD

echo "==> GitHub release"
gh release create "$TAG" --title "$TAG" --generate-notes >/dev/null

echo "==> Publishing formula to the tap ($TAP)"
work="$(mktemp -d)"
git clone -q "https://github.com/$TAP.git" "$work"
mkdir -p "$work/Formula"
cp "$FORMULA" "$work/Formula/server-manager.rb"
git -C "$work" add Formula/server-manager.rb
if git -C "$work" diff --cached --quiet; then
  echo "    (formula unchanged)"
else
  git -C "$work" commit -q -m "server-manager $VERSION"
  git -C "$work" push -q origin HEAD
fi
rm -rf "$work"

echo "==> Released $TAG  ·  tap updated  ·  brew install $TAP/server-manager"
