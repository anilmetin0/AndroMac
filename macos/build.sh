#!/bin/bash
# Builds the AndroMac.app bundle. No Xcode project — SPM plus manual packaging is enough.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/AndroMac.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AndroMac"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AndroMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Version: CI supplies it (ANDROMAC_VERSION=1.0.0, ANDROMAC_BUILD=42, ANDROMAC_COMMIT=abc1234);
# locally the values already in the plist are kept (version / build 1) and the commit reads "local".
PLIST="$APP/Contents/Info.plist"
if [[ -n "${ANDROMAC_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ANDROMAC_VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${ANDROMAC_BUILD:-1}" "$PLIST"
fi
if [[ -n "${ANDROMAC_COMMIT:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :AndroMacCommit $ANDROMAC_COMMIT" "$PLIST"
fi

# The icon is generated from source (no binary in the repo); generated once and kept under build/.
ICNS="build/AppIcon.icns"
if [[ ! -f "$ICNS" || Resources/make-icon.swift -nt "$ICNS" ]]; then
    # `swift script.swift` (the interpreter) crashes on beta toolchains; compiling and running is reliable.
    swiftc -O Resources/make-icon.swift -o build/make-icon
    build/make-icon build/AppIcon.iconset >/dev/null
    iconutil -c icns build/AppIcon.iconset -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Languages: English is the base language — the literals in the source code are the keys, so
# en.lproj maps every key to itself and tr.lproj holds the Turkish translations.
# Loaded through Bundle.main; the SwiftPM resource bundle (Bundle.module) is not used.
if [[ -d Resources/Localization ]]; then
    cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
fi

# UserNotifications and Keychain require a signed bundle.
#
# An ad-hoc signature (`-`) produces a DIFFERENT identity on every build; macOS then treats the
# app as a new one and Keychain asks for the password every time. If you have a persistent
# signing certificate, pass it via CODESIGN_IDENTITY and the prompt appears only once:
#     CODESIGN_IDENTITY="Apple Development: name@example.com" ./build.sh
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier dev.andromac --timestamp=none "$APP"
[[ "$IDENTITY" == "-" ]] && echo "Note: ad-hoc signature. Answer Always Allow to the Keychain prompt."

echo "Ready: $APP"
echo "Run: open $APP"
