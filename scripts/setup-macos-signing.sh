#!/bin/bash
# Creates a permanent self-signed code-signing certificate for the Mac app and uploads it to
# GitHub Actions secrets.
#
# Why: an ad-hoc signature is a different identity on every build, so the Keychain treats each
# update as a new app and asks for the login password again. Signed with one certificate, every
# build has the same designated requirement: after one "Always Allow" the Keychain stops asking,
# across updates. It does not replace notarization; Gatekeeper still needs the first-launch step.
#
# Run this ONCE. The certificate and its password stay under ~/.andromac/ (never in the repo);
# back that directory up, a new certificate means one more Keychain prompt for every user.
#
# Usage:  scripts/setup-macos-signing.sh [owner/repo]     (defaults to the current repo)
#         scripts/setup-macos-signing.sh --local          only import it for local builds
set -euo pipefail

NAME="AndroMac Self-Signed"
DIR="$HOME/.andromac"
P12="$DIR/macos-signing.p12"
PASSFILE="$DIR/macos-signing.password"
# macOS's own LibreSSL writes a PKCS#12 that `security import` reads without extra flags.
OPENSSL=/usr/bin/openssl

mkdir -p "$DIR"; chmod 700 "$DIR"

if [[ -f "$P12" ]]; then
    echo "Using existing certificate: $P12"
    PASS="$(cat "$PASSFILE")"
else
    PASS="$("$OPENSSL" rand -base64 24 | tr -d '/+=' | cut -c1-24)"
    umask 077
    printf '%s' "$PASS" > "$PASSFILE"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    "$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
        -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    "$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -passout "pass:$PASS" -out "$P12"
    echo "New certificate: $P12  (password: $PASSFILE; back both up)"
fi

# Local builds: macos/build.sh picks this identity up by name when CODESIGN_IDENTITY is unset.
if ! security find-certificate -c "$NAME" >/dev/null 2>&1; then
    security import "$P12" -P "$PASS" -T /usr/bin/codesign
    echo "Imported \"$NAME\" into the login keychain for local builds."
fi

[[ "${1:-}" == "--local" ]] && exit 0

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
base64 < "$P12" | tr -d '\n' | gh secret set MACOS_SIGNING_P12_BASE64 --repo "$REPO"
printf '%s' "$PASS" | gh secret set MACOS_SIGNING_PASSWORD --repo "$REPO"
echo "✓ 2 secrets set for $REPO. The next push to main signs the Mac app with \"$NAME\"."
