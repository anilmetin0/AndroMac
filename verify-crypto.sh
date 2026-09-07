#!/bin/bash
# Proves that the Android and macOS crypto implementations are byte-for-byte identical.
#
# Both sides implement P-256 ECDH + HKDF + AES-GCM INDEPENDENTLY (CryptoKit vs JCE).
# A single byte of difference (nonce layout, HKDF info, GCM tag position, X9.62 encoding)
# breaks the handshake silently on device and is very expensive to debug. This script
# catches exactly that.
set -euo pipefail
cd "$(dirname "$0")"

# JAVA_HOME wins if set; otherwise the newest JDK 25 on this Mac, then whatever java_home picks.
: "${JAVA_HOME:=$(/usr/libexec/java_home -v 25 2>/dev/null || /usr/libexec/java_home 2>/dev/null || true)}"
export JAVA_HOME

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ macOS vectors (Swift / CryptoKit)"
( cd macos && swift build -c release --product andromac-selftest >/dev/null )
macos/.build/release/andromac-selftest > "$TMP/swift.txt"

echo "→ Android vectors (Kotlin / JCE)"
( cd android && ./gradlew -q --console=plain :vectors:run ) > "$TMP/kotlin.txt"

if diff -u "$TMP/swift.txt" "$TMP/kotlin.txt"; then
    echo
    echo "✓ Crypto matches — all $(wc -l < "$TMP/swift.txt" | tr -d ' ') vectors identical"
else
    echo
    echo "✗ MISMATCH — the handshake will not work on device. See the diff above." >&2
    exit 1
fi
