#!/usr/bin/env bash
# Moves the bundled scrcpy (and the adb it ships) to its latest release: the pinned version and
# hash in macos/scripts/fetch-scrcpy.sh and the versions in THIRD-PARTY-NOTICES.md. The hash comes
# from the release's SHA256SUMS.txt; fetch-scrcpy.sh checks it again when the app is built.
# Commit the change as "fix(macos): bundle scrcpy <version>".
#
# The scrcpy workflow opens an issue when a new release is out. It cannot make this commit itself:
# main only takes commits whose checks ran on a push, and a push made with GITHUB_TOKEN starts no
# workflow.
set -euo pipefail
cd "$(dirname "$0")/.."

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
gh api repos/Genymobile/scrcpy/releases/latest > "$dir/release.json"
tag="$(jq -r .tag_name "$dir/release.json")"
[[ "$tag" =~ ^v[0-9]+(\.[0-9]+)+$ ]] || { echo "unexpected scrcpy tag '$tag'" >&2; exit 1; }
gh release download "$tag" --repo Genymobile/scrcpy --pattern SHA256SUMS.txt --dir "$dir"
version="$(python3 .github/scripts/bump-scrcpy.py "$dir/SHA256SUMS.txt" < "$dir/release.json")"
if [[ -z "$version" ]]; then
  echo "scrcpy is already at ${tag#v}."
else
  echo "scrcpy is now $version. Check it with macos/scripts/fetch-scrcpy.sh, then commit."
fi
