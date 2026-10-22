#!/usr/bin/env bash
set -euo pipefail

# Publishes a Floe release: builds and signs the app, packs a zip (for the
# updater) and a DMG (for people who install by dragging), tags the commit,
# creates the GitHub release and points the Homebrew formula at it.
#
#   scripts/release.sh 0.2.0
#
# Set FLOE_TAP_DIR to a checkout of Buecherfresser/homebrew-floe to also
# commit and push the updated formula there.

VERSION="${1:?usage: release.sh <version, e.g. 0.2.0>}"
VERSION="${VERSION#v}"
TAG="v$VERSION"
REPO="Buecherfresser/floe"
FORMULA="packaging/homebrew/floe.rb"

say() { echo "==> $*"; }
fail() { echo "Error: $*" >&2; exit 1; }

cd "$(dirname "$0")/.."
command -v gh >/dev/null || fail "This needs the GitHub CLI (brew install gh)."
[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG already exists."

# A stable signature keeps the Accessibility permission across updates for
# people who installed the zip or DMG.
./scripts/build-release.sh "$VERSION"
codesign --verify --deep --strict dist/Floe.app

ZIP="dist/Floe-$VERSION.zip"
DMG="dist/Floe-$VERSION.dmg"
say "Packing $ZIP..."
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent dist/Floe.app "$ZIP"

say "Packing $DMG..."
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto dist/Floe.app "$STAGING/Floe.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Floe" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

say "Tagging $TAG..."
git tag -a "$TAG" -m "Floe $VERSION"
git push origin "$TAG"

say "Creating the GitHub release..."
gh release create "$TAG" "$ZIP" "$DMG" --repo "$REPO" --title "Floe $VERSION" --generate-notes

say "Updating the Homebrew formula..."
SHA="$(curl -fsSL "https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz" | shasum -a 256 | awk '{print $1}')"
sed -i '' -E \
    -e "s|archive/refs/tags/v[^\"]+\.tar\.gz|archive/refs/tags/$TAG.tar.gz|" \
    -e "s|sha256 \"[0-9a-f]+\"|sha256 \"$SHA\"|" \
    "$FORMULA"
git commit -q -m "chore: point the Homebrew formula at $TAG" -- "$FORMULA"
git push origin HEAD

if [[ -n "${FLOE_TAP_DIR:-}" ]]; then
    mkdir -p "$FLOE_TAP_DIR/Formula"
    cp "$FORMULA" "$FLOE_TAP_DIR/Formula/floe.rb"
    git -C "$FLOE_TAP_DIR" add Formula/floe.rb
    git -C "$FLOE_TAP_DIR" commit -q -m "chore: update floe to $VERSION"
    git -C "$FLOE_TAP_DIR" push
    say "Pushed the formula to the tap."
else
    echo "Copy $FORMULA to Formula/floe.rb in Buecherfresser/homebrew-floe to update Homebrew."
fi

echo ""
echo "Floe $VERSION is out: https://github.com/$REPO/releases/tag/$TAG"
