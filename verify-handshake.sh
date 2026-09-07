#!/bin/bash
# End-to-end handshake test: the REAL Session.accept (Swift) talks to the REAL Session.connect
# (Kotlin) over loopback. The crypto vectors verify the bytes; this script verifies the
# SEQUENCE — frame order, the verification round with the nonce commitment, the pin check,
# that a wrong pin stops the phone before it reveals its static key, and that the SAS matches
# on both sides (and, being per-session, differs between rounds).
set -euo pipefail
cd "$(dirname "$0")"

# JAVA_HOME wins if set; otherwise the newest JDK 25 on this Mac, then whatever java_home picks.
: "${JAVA_HOME:=$(/usr/libexec/java_home -v 25 2>/dev/null || /usr/libexec/java_home 2>/dev/null || true)}"
export JAVA_HOME
PORT="${PORT:-47823}"

TMP="$(mktemp -d)"
cleanup() { [[ -n "${PID:-}" ]] && kill "$PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

( cd macos && swift build -c release --product andromac-selftest >/dev/null )

macos/.build/release/andromac-selftest handshake "$PORT" > "$TMP/mac.txt" 2>&1 &
PID=$!
for _ in $(seq 1 50); do grep -q "^listening=" "$TMP/mac.txt" 2>/dev/null && break; sleep 0.1; done
grep -q "^listening=" "$TMP/mac.txt" || { echo "✗ responder did not start"; cat "$TMP/mac.txt"; exit 1; }

( cd android && ./gradlew -q --console=plain :vectors:run --args="handshake 127.0.0.1 $PORT" ) > "$TMP/android.txt" 2>&1 || true
wait "$PID" 2>/dev/null || true
PID=""

echo "--- macOS (responder) ---"; cat "$TMP/mac.txt"
echo "--- Android (initiator) ---";  cat "$TMP/android.txt"
echo

fail() { echo "✗ $1" >&2; exit 1; }
mac_sas1=$(sed -n 's/^round1=untrusted sas=\([0-9]*\).*/\1/p' "$TMP/mac.txt")
and_sas1=$(sed -n 's/^round1=untrusted sas=\([0-9]*\).*/\1/p' "$TMP/android.txt")
mac_sas2=$(sed -n 's/^round3=connected sas=\([0-9]*\).*/\1/p' "$TMP/mac.txt")
and_sas2=$(sed -n 's/^round3=connected sas=\([0-9]*\).*/\1/p' "$TMP/android.txt")

[[ -n "$mac_sas1" && "$mac_sas1" == "$and_sas1" ]] || fail "round 1 SAS mismatch ('$mac_sas1' vs '$and_sas1')"
[[ -n "$mac_sas2" && "$mac_sas2" == "$and_sas2" ]] || fail "round 3 SAS mismatch ('$mac_sas2' vs '$and_sas2')"
[[ "$mac_sas1" != "$mac_sas2" ]] || fail "SAS repeated between rounds (must be bound to fresh nonces)"
grep -q "^round2=untrusted sas= mismatch=true" "$TMP/android.txt" || fail "wrong pin did not stop the phone before message 3"
grep -q "^round2=error" "$TMP/mac.txt" || fail "macOS did not see the wrong-pin attempt fail"
grep -q "^round3_hello=hello name=SelfTestMac" "$TMP/android.txt" || fail "Android did not receive hello"
grep -q "^round3_recv=clipboard text=merhaba mac" "$TMP/mac.txt" || fail "macOS did not receive the clipboard message"

# Counter progression: 12 frames must pass in order and intact in each direction.
expected="1,2,3,4,5,6,7,8,9,10,11,12"
mac_seq=$(sed -n "s/^round3_seq=//p" "$TMP/mac.txt")
and_seq=$(sed -n "s/^round3_seq=//p" "$TMP/android.txt")
[[ "$and_seq" == "$expected" ]] || fail "Android counter sequence broken: '$and_seq'"
[[ "$mac_seq" == "$expected" ]] || fail "macOS counter sequence broken: '$mac_seq'"

echo "✓ Handshake matches — SAS $mac_sas1 then $mac_sas2, 12 frames in order each way"
