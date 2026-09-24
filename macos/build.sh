#!/bin/bash
# Builds the AndroMac.app bundle. No Xcode project — SPM plus manual packaging is enough.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/AndroMac.app"

# The native build system, because the newer default one links through clang with --sysroot, which
# stamps the deployment target (14.0) as the binary's SDK version. AppKit then runs the app in its
# pre-26 compatibility mode: no Liquid Glass window chrome, old sidebar, small panel corners.
BUILD=(swift build -c "$CONFIG" --build-system native)
"${BUILD[@]}"
BIN="$("${BUILD[@]}" --show-bin-path)/AndroMac"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AndroMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Screen mirroring: scrcpy and adb, fetched and checksum-verified by scripts/fetch-scrcpy.sh.
# Without them the app looks for a Homebrew scrcpy instead, so a plain source build still works.
if [[ -d vendor/scrcpy ]]; then
    cp vendor/scrcpy/scrcpy vendor/scrcpy/adb "$APP/Contents/MacOS/"
    cp vendor/scrcpy/scrcpy-server vendor/scrcpy/scrcpy.png "$APP/Contents/Resources/"
    mkdir -p "$APP/Contents/Resources/Licenses"
    cp vendor/scrcpy/LICENSE "$APP/Contents/Resources/Licenses/scrcpy-LICENSE.txt"
    cp ../THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/Licenses/"
fi

# Version: CI supplies it (ANDROMAC_VERSION=1.0.0, ANDROMAC_BUILD=42, ANDROMAC_COMMIT=abc1234);
# locally it is the VERSION file, build 1, and the commit reads "local", as on Android.
PLIST="$APP/Contents/Info.plist"
: "${ANDROMAC_VERSION:=$(tr -d '[:space:]' < ../VERSION)}"
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

# The same icon as an asset catalog (CFBundleIconName). Notification Center looks the icon up by
# bundle identifier, and on macOS 26 that lookup finds only Assets.car: with the .icns alone every
# banner showed the blank app template. The .icns stays for older systems and for Finder.
CATALOG="build/Assets.xcassets/AppIcon.appiconset"
rm -rf build/Assets.xcassets && mkdir -p "$CATALOG"
cp build/AppIcon.iconset/*.png "$CATALOG/"
images=()
for size in 16 32 128 256 512; do
    images+=("{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"1x\",\"filename\":\"icon_${size}x${size}.png\"}")
    images+=("{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"2x\",\"filename\":\"icon_${size}x${size}@2x.png\"}")
done
(IFS=,; echo "{\"images\":[${images[*]}],\"info\":{\"version\":1,\"author\":\"xcode\"}}") > "$CATALOG/Contents.json"
# The GitHub mark beside the version, a template image: it takes the text colour it sits in.
MARK="build/Assets.xcassets/GitHubMark.imageset"
mkdir -p "$MARK" && cp Resources/GitHubMark.svg "$MARK/"
echo '{"images":[{"idiom":"universal","filename":"GitHubMark.svg"}],"info":{"version":1,"author":"xcode"},"properties":{"preserves-vector-representation":true,"template-rendering-intent":"template"}}' \
    > "$MARK/Contents.json"
xcrun actool build/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist build/assets-info.plist >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$PLIST"

# Languages: English is the base language — the literals in the source code are the keys, so
# en.lproj maps every key to itself and tr.lproj holds the Turkish translations.
# Loaded through Bundle.main; the SwiftPM resource bundle (Bundle.module) is not used.
if [[ -d Resources/Localization ]]; then
    cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
fi

# UserNotifications and Keychain require a signed bundle.
#
# An ad-hoc signature (`-`) produces a DIFFERENT identity on every build; macOS then treats the
# app as a new one and Keychain asks for the password every time. One persistent certificate
# keeps the designated requirement (the Keychain may still ask once per update without a
# Developer ID): `scripts/setup-macos-signing.sh --local` creates "AndroMac Self-Signed" and
# this script uses it when CODESIGN_IDENTITY is unset. CI passes its own through
# CODESIGN_IDENTITY and CODESIGN_KEYCHAIN. The first local build with it asks once to use the
# key (login password, then Always Allow); CODESIGN_IDENTITY=- signs ad-hoc instead.
SELF_SIGNED="AndroMac Self-Signed"
if [[ -z "${CODESIGN_IDENTITY:-}" ]] && security find-certificate -c "$SELF_SIGNED" >/dev/null 2>&1; then
    CODESIGN_IDENTITY="$SELF_SIGNED"
fi
IDENTITY="${CODESIGN_IDENTITY:--}"
SIGN=(codesign --force --sign "$IDENTITY" --timestamp=none)
[[ -n "${CODESIGN_KEYCHAIN:-}" ]] && SIGN+=(--keychain "$CODESIGN_KEYCHAIN")
# Nested executables first: the bundle's signature seals them as they are.
for helper in "$APP/Contents/MacOS/scrcpy" "$APP/Contents/MacOS/adb"; do
    [[ -f "$helper" ]] && "${SIGN[@]}" "$helper"
done
"${SIGN[@]}" --identifier dev.andromac "$APP"
echo "Signed with: $IDENTITY"
[[ "$IDENTITY" == "-" ]] && echo "Note: ad-hoc signature. Answer Always Allow to the Keychain prompt."

echo "Ready: $APP"
echo "Run: open $APP"
