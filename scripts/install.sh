#!/usr/bin/env bash
set -euo pipefail

# Installs or updates Floe by building it on this Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/Buecherfresser/floe/main/scripts/install.sh | bash
#
# Options:
#   --version X.Y.Z   install that release instead of the latest
#   --source DIR      build a local checkout instead of downloading a release
#   --app-dir DIR     install somewhere other than /Applications
#   --no-launch       don't start Floe afterwards
#   --update          used by Floe's updater: quieter output

REPO="Buecherfresser/floe"
APP_DIR="/Applications"
VERSION=""
SOURCE=""
LAUNCH=1
UPDATE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)   VERSION="${2#v}"; shift 2 ;;
        --source)    SOURCE="$2"; shift 2 ;;
        --app-dir)   APP_DIR="$2"; shift 2 ;;
        --no-launch) LAUNCH=0; shift ;;
        --update)    UPDATE=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

say() { echo "==> $*"; }
fail() { echo "Error: $*" >&2; exit 1; }

# macOS 26 or later
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$MACOS_MAJOR" -ge 26 ]] || fail "Floe needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))."

# Floe is built here, which needs Apple's Command Line Tools with Swift 6.2.
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    say "Floe is built on your Mac, which needs Apple's Command Line Tools."
    xcode-select --install 2>/dev/null || true
    fail "Run this script again once the Command Line Tools are installed."
fi
SWIFT_VERSION="$(swift --version 2>&1 | grep -oE 'Swift version [0-9]+\.[0-9]+' | head -1 | awk '{print $3}')"
SWIFT_MAJOR="${SWIFT_VERSION%%.*}"
SWIFT_MINOR="${SWIFT_VERSION#*.}"
if [[ "$SWIFT_MAJOR" -lt 6 || ( "$SWIFT_MAJOR" -eq 6 && "$SWIFT_MINOR" -lt 2 ) ]]; then
    fail "Floe needs Swift 6.2 or later (found ${SWIFT_VERSION:-none}). Update the Command Line Tools in System Settings › General › Software Update."
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -n "$SOURCE" ]]; then
    SRC="$(cd "$SOURCE" && pwd)"
    VERSION="${VERSION:-$(git -C "$SRC" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
    VERSION="${VERSION:-0.0.0}"
else
    if [[ -z "$VERSION" ]]; then
        TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1 || true)"
        [[ -n "$TAG" ]] || fail "Couldn't find a Floe release on GitHub. Check https://github.com/$REPO/releases."
        VERSION="${TAG#v}"
    fi
    say "Downloading Floe $VERSION..."
    curl -fsSL "https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz" | tar -xz -C "$WORK"
    SRC="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -1)"
fi

say "Building Floe $VERSION (takes about a minute)..."
if ! (cd "$SRC" && SIGN_IDENTITY=- ./scripts/build-release.sh "$VERSION") > "$WORK/build.log" 2>&1; then
    tail -30 "$WORK/build.log" >&2
    fail "The build failed."
fi
BUILT="$SRC/dist/Floe.app"

# A stable signature lets macOS keep Floe's Accessibility permission
# across updates.
if [[ -x "$SRC/scripts/sign-local.sh" ]]; then
    "$SRC/scripts/sign-local.sh" "$BUILT"
fi

TARGET="$APP_DIR/Floe.app"
[[ -w "$APP_DIR" ]] || fail "Can't write to $APP_DIR. Try --app-dir \"\$HOME/Applications\"."

# Quit the Floe being replaced (and only that one).
if pgrep -f "$TARGET/Contents/MacOS/Floe" >/dev/null 2>&1; then
    say "Quitting the running Floe..."
    pkill -TERM -f "$TARGET/Contents/MacOS/Floe" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        pgrep -f "$TARGET/Contents/MacOS/Floe" >/dev/null 2>&1 || break
        sleep 1
    done
    pkill -KILL -f "$TARGET/Contents/MacOS/Floe" 2>/dev/null || true
fi

say "Installing to $TARGET..."
rm -rf "$TARGET"
ditto "$BUILT" "$TARGET"

# Tells Floe's updater to update through this script.
MARKER_DIR="$HOME/Library/Application Support/Floe"
mkdir -p "$MARKER_DIR"
printf 'script\n' > "$MARKER_DIR/install-method"

if [[ "$LAUNCH" -eq 1 ]]; then
    open "$TARGET"
fi

echo ""
echo "Floe $VERSION is installed."
if [[ "$UPDATE" -eq 0 ]]; then
    echo "On first launch macOS asks for Accessibility access. After that, Floe updates itself."
fi
