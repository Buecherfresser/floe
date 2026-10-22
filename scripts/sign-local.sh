#!/usr/bin/env bash
set -euo pipefail

# Signs Floe.app with a certificate that stays the same across builds, so
# macOS keeps Floe's Accessibility permission after updates. An ad-hoc
# signature changes with every build and macOS treats each one as a new app.
#
#   scripts/sign-local.sh /Applications/Floe.app
#
# Uses an Apple Development or Developer ID certificate if you have one.
# Otherwise it creates a self-signed "Floe Local Signing" certificate in its
# own keychain under ~/Library/Application Support/Floe/signing. Trusting that
# certificate for code signing asks for your password once.

# --if-set-up only re-signs: it doesn't create the certificate, since that
# asks for a password. Floe's updater uses it.
IF_SET_UP=0
if [[ "${1:-}" == "--if-set-up" ]]; then IF_SET_UP=1; shift; fi
APP="${1:?usage: sign-local.sh [--if-set-up] <path to Floe.app>}"
IDENTITY_NAME="Floe Local Signing"
SIGNING_DIR="$HOME/Library/Application Support/Floe/signing"
KEYCHAIN="$SIGNING_DIR/floe-signing.keychain-db"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"

sign_adhoc() {
    echo "==> Signing ad-hoc. macOS will ask for Accessibility again after the next update."
    codesign --force --deep --sign - "$APP"
}

# A real Apple certificate beats a self-signed one. FLOE_LOCAL_SIGNING=1
# skips it, to try the self-signed route on a Mac that has one.
APPLE_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Developer ID Application|Apple Development): [^"]+"' | head -1 | tr -d '"' || true)"
if [[ -n "$APPLE_IDENTITY" && "${FLOE_LOCAL_SIGNING:-0}" != "1" ]]; then
    echo "==> Signing with $APPLE_IDENTITY"
    codesign --force --deep --sign "$APPLE_IDENTITY" "$APP"
    exit 0
fi

create_identity() {
    echo "==> Creating the \"$IDENTITY_NAME\" certificate (once)..."
    mkdir -p "$SIGNING_DIR"
    chmod 700 "$SIGNING_DIR"

    local work
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' RETURN

    local password
    password="$(/usr/bin/openssl rand -hex 24)"

    cat > "$work/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Floe Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$work/key.pem" -out "$work/cert.pem" -config "$work/cert.cnf" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
        -out "$work/identity.p12" -passout pass:"$password" -name "$IDENTITY_NAME" 2>/dev/null

    rm -f "$KEYCHAIN"
    security create-keychain -p "$password" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"   # don't lock after a timeout
    security unlock-keychain -p "$password" "$KEYCHAIN"
    security import "$work/identity.p12" -k "$KEYCHAIN" -P "$password" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN" >/dev/null

    # codesign only uses a self-signed certificate that's trusted for code
    # signing. This is the step that asks for your password.
    echo "==> macOS will ask for your password to trust the certificate for code signing."
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$work/cert.pem"

    printf '%s' "$password" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
}

if [[ ! -f "$KEYCHAIN" || ! -f "$PASSWORD_FILE" ]]; then
    if [[ "$IF_SET_UP" -eq 1 ]]; then
        echo "==> Local signing isn't set up; leaving the app as it is."
        exit 0
    fi
    if ! create_identity; then
        echo "    Couldn't set up the certificate."
        sign_adhoc
        exit 0
    fi
fi

security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"

echo "==> Signing with $IDENTITY_NAME"
if ! codesign --force --deep --sign "$IDENTITY_NAME" --keychain "$KEYCHAIN" "$APP" 2>/dev/null; then
    # Some macOS versions only look up identities in keychains on the search list.
    SEARCH_LIST=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#\"}"
        line="${line%\"}"
        [[ -n "$line" ]] && SEARCH_LIST+=("$line")
    done < <(security list-keychains -d user)
    if ! printf '%s\n' "${SEARCH_LIST[@]}" | grep -qxF "$KEYCHAIN"; then
        security list-keychains -d user -s "${SEARCH_LIST[@]}" "$KEYCHAIN"
    fi
    if ! codesign --force --deep --sign "$IDENTITY_NAME" --keychain "$KEYCHAIN" "$APP"; then
        echo "    Signing with $IDENTITY_NAME failed."
        sign_adhoc
    fi
fi
