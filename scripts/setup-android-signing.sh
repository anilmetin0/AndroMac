#!/bin/bash
# Creates a permanent Android release signing key and uploads it to GitHub Actions secrets.
#
# Why: an APK signed with a debug key installs, but the runner's debug key differs on every
# build, so users could never update in place ("signature mismatch"). Run this ONCE; the key
# and password stay under ~/.andromac/ (never in the repo), and the same values go to GitHub
# as secrets. Back up that directory — if the key is lost, the update path is gone.
#
# Usage:  scripts/setup-android-signing.sh [owner/repo]     (defaults to the current repo)
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
DIR="$HOME/.andromac"
KS="$DIR/release.keystore"
PASSFILE="$DIR/release.password"
ALIAS="andromac"
# JAVA_HOME wins if set; otherwise the newest JDK 25 on this Mac, then whatever java_home picks.
: "${JAVA_HOME:=$(/usr/libexec/java_home -v 25 2>/dev/null || /usr/libexec/java_home 2>/dev/null || true)}"
KEYTOOL="$JAVA_HOME/bin/keytool"; [[ -x "$KEYTOOL" ]] || KEYTOOL="keytool"

mkdir -p "$DIR"; chmod 700 "$DIR"

if [[ -f "$KS" ]]; then
    echo "Using existing key: $KS"
    PASS="$(cat "$PASSFILE")"
else
    PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
    umask 077
    printf '%s' "$PASS" > "$PASSFILE"
    "$KEYTOOL" -genkeypair -v \
        -keystore "$KS" -storepass "$PASS" -keypass "$PASS" \
        -alias "$ALIAS" -keyalg EC -groupname secp256r1 -sigalg SHA256withECDSA \
        -validity 10000 -dname "CN=AndroMac, O=AndroMac"
    echo "New key: $KS  (password: $PASSFILE — back it up; losing it closes the update path)"
fi

base64 < "$KS" | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64 --repo "$REPO"
printf '%s' "$PASS"  | gh secret set ANDROID_KEYSTORE_PASSWORD --repo "$REPO"
printf '%s' "$ALIAS" | gh secret set ANDROID_KEY_ALIAS --repo "$REPO"
printf '%s' "$PASS"  | gh secret set ANDROID_KEY_PASSWORD --repo "$REPO"

echo "✓ 4 secrets set for $REPO. The next push to main is signed with the release key."
echo "  To build locally with the same key:"
echo "  ANDROID_KEYSTORE_PATH=$KS ANDROID_KEYSTORE_PASSWORD=\$(cat $PASSFILE) ANDROID_KEY_ALIAS=$ALIAS ANDROID_KEY_PASSWORD=\$(cat $PASSFILE) ./gradlew :app:assembleRelease"
