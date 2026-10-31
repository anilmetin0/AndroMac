#!/usr/bin/env bash
# Pins the stable release's DMG checksum in Casks/andromac.rb, so Homebrew verifies the download.
# Run it after the build that publishes v<VERSION>, and again after a re-published one, then
# commit the change as "chore(cask): pin the <VERSION> checksum".
#
# The hash comes from the release's SHA256SUMS.txt and is checked against the DMG the release
# serves. CI cannot do this itself: main only takes commits whose checks ran on a push, and a
# push made with GITHUB_TOKEN starts no workflow.
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(tr -d '[:space:]' < VERSION)"
dmg="AndroMac-$version-macOS-arm64.dmg"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

gh release download "v$version" --pattern SHA256SUMS.txt --pattern "$dmg" --dir "$dir"
sha="$(awk -v f="$dmg" '{ n = $2; sub(/^\*/, "", n) } n == f { print $1 }' "$dir/SHA256SUMS.txt")"
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "SHA256SUMS.txt of v$version has no hash for $dmg" >&2; exit 1; }
actual="$(shasum -a 256 "$dir/$dmg" | awk '{ print $1 }')"
[[ "$actual" == "$sha" ]] || { echo "$dmg is $actual, SHA256SUMS.txt says $sha" >&2; exit 1; }

if grep -qx "  sha256 \"$sha\"" Casks/andromac.rb; then
  echo "Casks/andromac.rb already pins $sha."
  exit 0
fi
sed -i '' -E "s/^  sha256 .*/  sha256 \"$sha\"/" Casks/andromac.rb
grep -qx "  sha256 \"$sha\"" Casks/andromac.rb || { echo "no sha256 line in Casks/andromac.rb" >&2; exit 1; }
echo "Casks/andromac.rb now pins $sha for $version."
