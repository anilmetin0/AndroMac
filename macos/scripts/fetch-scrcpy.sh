#!/bin/bash
# Fetches the scrcpy release the Mac app ships for screen mirroring into macos/vendor/scrcpy:
# scrcpy, adb (thinned to arm64), scrcpy-server and the window icon, checked against the pinned SHA-256 first.
# build.sh bundles them when the directory exists. Bump VERSION and SHA256 together; the hash is
# the `digest` GitHub lists for scrcpy-macos-aarch64-v<VERSION>.tar.gz on the release page.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="4.1"
SHA256="20fd47c9014dd5e0fa77091f3cb7adbda8445a360c4584aeaa0150b5b3988ff3"
NAME="scrcpy-macos-aarch64-v$VERSION"
DEST="vendor/scrcpy"

if [[ "$(cat "$DEST/.version" 2>/dev/null)" == "$VERSION" ]]; then
    echo "scrcpy $VERSION already in $DEST"
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/$NAME.tar.gz" \
    "https://github.com/Genymobile/scrcpy/releases/download/v$VERSION/$NAME.tar.gz"
echo "$SHA256  $tmp/$NAME.tar.gz" | shasum -a 256 -c -
tar xzf "$tmp/$NAME.tar.gz" -C "$tmp"

rm -rf "$DEST"
mkdir -p "$DEST"
cp "$tmp/$NAME/scrcpy" "$tmp/$NAME/scrcpy-server" "$tmp/$NAME/scrcpy.png" "$tmp/$NAME/LICENSE" "$DEST/"
lipo "$tmp/$NAME/adb" -thin arm64 -output "$DEST/adb" 2>/dev/null || cp "$tmp/$NAME/adb" "$DEST/"
echo "$VERSION" > "$DEST/.version"
echo "scrcpy $VERSION → $DEST"
