#!/usr/bin/env bash
set -uo pipefail

# Removes Floe and everything it leaves behind.
#
#   curl -fsSL https://raw.githubusercontent.com/Buecherfresser/floe/main/scripts/uninstall.sh | bash
#
# Options:
#   --app PATH        the Floe.app to remove (default: /Applications/Floe.app,
#                     then ~/Applications/Floe.app)
#   --keep-settings   keep ~/.config/floe

BUNDLE_ID="com.jonasdrechsel.floe"
APP=""
KEEP_SETTINGS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)           APP="$2"; shift 2 ;;
        --keep-settings) KEEP_SETTINGS=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

say() { echo "==> $*"; }

if [[ -z "$APP" ]]; then
    for candidate in /Applications/Floe.app "$HOME/Applications/Floe.app"; do
        if [[ -e "$candidate" ]]; then APP="$candidate"; break; fi
    done
fi

# Quit every running Floe.
if pgrep -f "Floe.app/Contents/MacOS/Floe" >/dev/null 2>&1; then
    say "Quitting Floe..."
    pkill -TERM -f "Floe.app/Contents/MacOS/Floe" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        pgrep -f "Floe.app/Contents/MacOS/Floe" >/dev/null 2>&1 || break
        sleep 1
    done
    pkill -KILL -f "Floe.app/Contents/MacOS/Floe" 2>/dev/null || true
fi

# Homebrew owns its copy; /Applications only holds a link to it.
BREW="$(command -v brew || true)"
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -z "$BREW" && -x "$candidate" ]] && BREW="$candidate"
done
if [[ -n "$BREW" ]] && "$BREW" list --formula floe >/dev/null 2>&1; then
    say "Removing the Homebrew formula..."
    "$BREW" uninstall floe
    "$BREW" untap buecherfresser/floe 2>/dev/null || true
fi

if [[ -n "$APP" && ( -e "$APP" || -L "$APP" ) ]]; then
    say "Removing $APP..."
    rm -rf "$APP"
fi

# The certificate that kept the Accessibility permission across updates.
SIGNING_DIR="$HOME/Library/Application Support/Floe/signing"
KEYCHAIN="$SIGNING_DIR/floe-signing.keychain-db"
if [[ -f "$KEYCHAIN" ]]; then
    say "Removing the Floe Local Signing certificate (macOS may ask for your password)..."
    CERT="$(mktemp)"
    if security find-certificate -c "Floe Local Signing" -p "$KEYCHAIN" > "$CERT" 2>/dev/null; then
        security remove-trusted-cert "$CERT" 2>/dev/null || true
    fi
    rm -f "$CERT"
    # Also takes the keychain off the search list if it was added.
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
fi

say "Removing Floe's files..."
rm -rf "$HOME/Library/Application Support/Floe" "$HOME/Library/Logs/Floe"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
if [[ "$KEEP_SETTINGS" -eq 0 ]]; then
    rm -rf "$HOME/.config/floe"
fi

say "Removing Floe from Accessibility..."
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true

echo ""
echo "Floe is uninstalled."
if [[ "$KEEP_SETTINGS" -eq 1 ]]; then
    echo "Your settings are still in ~/.config/floe."
fi
