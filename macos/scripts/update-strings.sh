#!/usr/bin/env bash
# Usage: macos/scripts/update-strings.sh [--check]
#
# English is the base language. This script extracts the strings from the sources with swiftc,
# rewrites en.lproj/Localizable.strings (key = value) and reports the missing/orphaned keys
# for every other .lproj.
#
#   (no flag)    appends the missing keys under "/* TODO translate */" with the English value
#   --check      changes no file, exits 1 if any key is missing (CI)
#
# To add a new language: copy Resources/Localization/<code>.lproj/Localizable.strings from
# en.lproj, translate the values, open a PR. No code change is needed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."          # macos/
MACOS="$PWD"

# The AndroMacKit module must be importable during extraction.
swift build >/dev/null
BIN="$(swift build --show-bin-path)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# -c is required: with -typecheck no .stringsdata is written. Let the object files land in TMP.
cd "$TMP"
swiftc -c \
    -emit-localized-strings -emit-localized-strings-path "$TMP" \
    -module-name AndroMac \
    -target "$(uname -m)-apple-macos14.0" \
    -sdk "$(xcrun --show-sdk-path)" \
    -I "$BIN" -I "$BIN/Modules" \
    "$MACOS"/Sources/AndroMac/*.swift
cd "$MACOS"

python3 - "$TMP" "${1:-}" <<'PY'
import glob, json, pathlib, re, sys

tmp, flag = pathlib.Path(sys.argv[1]), sys.argv[2]
check = flag == "--check"
if flag and not check:
    raise SystemExit(f"unknown option: {flag}")

keys = set()
for path in glob.glob(str(tmp / "*.stringsdata")):
    with open(path, encoding="utf-8") as f:
        for entries in json.load(f).get("tables", {}).values():
            keys.update(e["key"] for e in entries)
keys.discard("")            # a Picker("") with a hidden label — it has no place in .strings

base = pathlib.Path("Resources/Localization")
english = base / "en.lproj/Localizable.strings"

# Deliberately simple: line-based parsing, because the generated format always puts one
# entry on one line. If a translation file ever writes a multi-line value, this needs to be
# replaced with a real .strings parser.
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def esc(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def unesc(text):
    return text.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def parse(path):
    if not path.exists():
        return {}
    out = {}
    for line in path.read_text(encoding="utf-8").split("\n"):
        m = ENTRY.match(line)
        if m:
            out[unesc(m.group(1))] = unesc(m.group(2))
    return out


ordered = sorted(keys, key=str.lower)

if not check:
    english.parent.mkdir(parents=True, exist_ok=True)
    english.write_text(
        "/* Base language. Do not edit by hand — run macos/scripts/update-strings.sh */\n\n"
        + "".join(f'"{esc(k)}" = "{esc(k)}";\n' for k in ordered),
        encoding="utf-8",
    )
print(f"en.lproj: {len(keys)} keys")

failed = False
for path in sorted(base.glob("*.lproj/Localizable.strings")):
    if path == english:
        continue
    existing = parse(path)
    missing = [k for k in ordered if k not in existing]
    orphan = sorted(set(existing) - keys, key=str.lower)
    name = path.parent.name
    print(f"{name}: {len(existing)} translated, {len(missing)} missing, {len(orphan)} orphaned")
    for k in orphan:
        print(f"    orphaned (not in the code): {k!r}")
    if not missing:
        continue
    for k in missing:
        print(f"    missing: {k!r}")
    if check:
        failed = True
    else:
        with path.open("a", encoding="utf-8") as f:
            f.write("\n/* TODO translate */\n")
            f.write("".join(f'"{esc(k)}" = "{esc(k)}";\n' for k in missing))
        print(f"    → {len(missing)} keys added with the English value")

if failed:
    raise SystemExit("translations are missing (--check)")
PY

plutil -lint Resources/Localization/*/Localizable.strings
