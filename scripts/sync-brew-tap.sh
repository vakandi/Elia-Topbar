#!/usr/bin/env bash
# Publish the cask from this repo to the Homebrew tap after a release.
#
# Homebrew requires casks to live inside a tap repository, but the version and
# sha256 only exist once the GitHub release is out. So the cask is versioned
# HERE (reviewed alongside the code it ships) and copied to the tap on release.
#
# Usage:  ./scripts/sync-brew-tap.sh          # after gh release create
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP_REPO="vakandi/homebrew-tap"
CASK_NAME="eliatopbar"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$REPO_ROOT/Casks/$CASK_NAME.rb" ]] || die "Casks/$CASK_NAME.rb not found"

VERSION="$(grep -oE 'version "[^"]+"' "$REPO_ROOT/Casks/$CASK_NAME.rb" | head -1 | grep -oE '[0-9][^"]*')"
[[ -n "$VERSION" ]] || die "could not read version from the cask"

# The sha256 in the cask must match the DMG that was actually published,
# otherwise the tap installs a cask that can never verify.
DMG="$REPO_ROOT/EliaTopBar-v$VERSION.dmg"
[[ -f "$DMG" ]] || die "DMG not found: $DMG"
ACTUAL="$(shasum -a 256 "$DMG" | awk '{print $1}')"
DECLARED="$(grep -oE 'sha256 "[a-f0-9]+"' "$REPO_ROOT/Casks/$CASK_NAME.rb" | head -1 | grep -oE '[a-f0-9]{64}')"
[[ "$ACTUAL" == "$DECLARED" ]] || die "sha256 mismatch
  DMG:    $ACTUAL
  cask:   $DECLARED"

command -v gh >/dev/null || die "gh not found"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

gh repo clone "$TAP_REPO" "$TMP/tap" -- --depth=1 >/dev/null
mkdir -p "$TMP/tap/Casks"
cp "$REPO_ROOT/Casks/$CASK_NAME.rb" "$TMP/tap/Casks/$CASK_NAME.rb"

cd "$TMP/tap"
if git diff --quiet -- Casks "$CASK_NAME.rb" 2>/dev/null && [ -z "$(git status --porcelain)" ]; then
  echo "Tap already up to date (v$VERSION)."
  exit 0
fi
git add "Casks/$CASK_NAME.rb"
git -c user.name="$(gh api user --jq .name)" \
    -c user.email="$(gh api user --jq .email)" \
    commit -m "chore(cask): eliatopbar $VERSION

sha256 $ACTUAL matches EliaTopBar-v$VERSION.dmg."
git push origin main

echo "Published cask v$VERSION to $TAP_REPO"
echo "Verify with:  brew update && brew reinstall --cask vakandi/tap/$CASK_NAME"