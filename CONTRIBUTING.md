# Contributing

Thanks for looking. AndroMac is a small project with a narrow scope and a few rules that are not
negotiable, so it is worth reading this before writing code.

The repository language is English: code, comments, commit messages, issues and documentation.
Turkish exists as a translation, in `README.tr.md`, `CHANGELOG.tr.md` and the app resources.
Issues and pull request descriptions in Turkish are fine.

## Scope

Deliberately out of scope: SMS, call control, more than one Mac, and any access over the
internet. Any number of phones, one Mac, one local network. A pull request that adds one of
those will be closed however good the code is.

## Toolchain

| | Version |
|---|---|
| macOS | 14 Sonoma or later to run, and to build |
| Xcode | 26.6 or later, for the Swift 6.2 toolchain |
| JDK | 25 |
| Android SDK | platform 37 (Android 17), build-tools 36.0.0 |
| Gradle | 9.7.1, through the wrapper, downloaded automatically |
| Android Gradle Plugin | 9.4.0, with its built-in Kotlin |
| Kotlin | 2.4.10, for the plain-JVM `vectors` module only |
| Python 3 | only for `macos/scripts/update-strings.sh` |

The Android build targets Java 21 bytecode and `minSdk` 29, which is Android 10.

`JAVA_HOME` is used if it is set. Otherwise the scripts pick the newest JDK 25 that `java_home`
reports, and fall back to the default JDK, so a normal machine needs no setup.

## Build

```bash
./verify-crypto.sh && ./verify-handshake.sh          # proof first

macos/build.sh                                       # → macos/build/AndroMac.app
open macos/build/AndroMac.app

android/gradlew -p android :app:installDebug         # phone attached over adb
```

`android/gradlew -p android :app:assembleDebug` builds the APK without installing it.
`macos/build.sh debug` builds the unoptimized macOS binary.

Unit tests live next to the pure logic they cover and run without a device:

```bash
(cd macos && swift test)                             # macos/Tests/AndroMacKitTests
android/gradlew -p android :vectors:test             # android/vectors/src/test
```

Platform-free Kotlin (anything in `core/` or `feature/` that imports no `android.*` package) can be
added to the `vectors` source set in `android/vectors/build.gradle.kts` and tested there.

`build.sh` signs the bundle ad-hoc, and an ad-hoc signature is a different identity on every
build, so the Keychain asks for permission every time you launch. With a persistent certificate
it asks once:

```bash
CODESIGN_IDENTITY="Apple Development: you@example.com" macos/build.sh
```

To watch a live connection:

```bash
adb logcat -s AndroMac
log stream --predicate 'senderImagePath CONTAINS "AndroMac"'
```

Neither log carries message content or key material, and it must stay that way.

## The two verification scripts

The crypto is implemented twice and independently: CryptoKit on macOS, JCE on Android. A single
byte of disagreement, in the X9.62 encoding, the HKDF info string, the nonce layout or the GCM tag
position, breaks the handshake on device with no useful error. Both scripts exist so that the
agreement is proven rather than assumed.

| Script | What it proves |
|---|---|
| `verify-crypto.sh` | CryptoKit and JCE produce identical vectors: key encoding, HKDF, nonce layout, GCM tag position, SAS derivation. |
| `verify-handshake.sh` | The real `Session.accept` in Swift talks to the real `Session.connect` in Kotlin over loopback: frame order, the confirmation round, the pin check, the SAS matching on both sides, and 12 frames in counter order in each direction. |

Run **both** whenever you touch crypto, the handshake, framing or the message set. Passing one
does not imply the other: during development the vectors passed while the handshake failed,
because the `dh2` and `dh3` order was written the wrong way round on macOS. CI runs both on every
push, on every branch.

## Rules

**Keep the energy contract.** The rules in [docs/ENERGY.md](docs/ENERGY.md) are part of the
protocol, not an implementation detail. No periodic timer on the phone, no polling, no wakelock,
and filtering at the source rather than on the Mac. Expensive work belongs on the Mac, which is on
wall power. If a change needs a new wakeup on the phone, say why in the pull request description.

**No third-party dependencies.** Neither shipped app has one, and neither should. Network
framework, CryptoKit, AppKit, UserNotifications, `NsdManager`, `javax.crypto` and `org.json` all
ship with the platforms. The one exception is the `vectors` module, which runs on a plain JVM
where `org.json` is not part of the runtime, so it declares that single dependency. Before adding
anything, check what the platform already gives you.

**One source of truth for the wire.** [docs/PROTOCOL.md](docs/PROTOCOL.md) describes the format
both sides are written against. If you change the wire format or the message set, update it in the
same pull request.

**Never hardcode a user-visible string.** On Android use resource ids, `@string/settings_language`
and `getString(R.string.…)`, and add the English text to `values/strings.xml` first. On macOS the
English literal is the key: `Text("Remove pairing")`, `String(localized: "Restart")`. After adding
a new one, run `macos/scripts/update-strings.sh` with no flag to regenerate the `.strings` files,
then fill in the translations it marked `TODO translate`.

**Validate what arrives.** The sender's limits are not the receiver's guarantee. Every incoming
field has its own length check on the receiving side, and new message fields need one too.

## Adding a language

A new language is one translation file per platform and no code change on either side.

### Android

1. Copy `android/app/src/main/res/values/strings.xml` to
   `android/app/src/main/res/values-<code>/strings.xml`.
2. Translate the values only. Keep every `name` key, every placeholder such as `%1$s` and `%d`,
   and every plural form exactly as it is, or the format calls will crash at runtime.
3. Add the code to `android/app/src/main/res/xml/locales_config.xml`:

   ```xml
   <locale android:name="<code>" />
   ```

   That list is what the Android 13+ per-app language picker offers.
4. Build: `android/gradlew -p android :app:assembleDebug`.

### macOS

1. Copy `macos/Resources/Localization/en.lproj/Localizable.strings` to
   `macos/Resources/Localization/<code>.lproj/Localizable.strings`.
2. Translate the right-hand side only. The left-hand side is the key, which is the English source
   literal; changing it breaks the lookup.
3. Also copy `macos/Resources/Localization/tr.lproj/InfoPlist.strings` to your `.lproj` and
   translate it. It holds the Local Network permission text macOS shows on first launch. There is
   no `en.lproj` version because `Info.plist` already carries the English wording, and
   `update-strings.sh` does not check this file, so it is easy to forget.
4. Run `macos/scripts/update-strings.sh --check`. It reports keys that are missing from any
   `.lproj` and keys that no longer exist in the code. CI runs the same check, so a half-finished
   translation fails the build.

The in-app language picker lists whatever it finds in the bundle, so there is nothing else to do.

## Pull requests

- Keep the change small and focused. One subject per pull request.
- Use the checklist in the pull request template, and say which devices and OS versions you tested
  on.
- Add an entry to `CHANGELOG.md` and `CHANGELOG.tr.md` under the section matching `VERSION`, if
  the change is user-visible. That section is the release notes of the rolling build and is edited
  in place; the release job reads it and fails when one language is missing.
- Do not bump the `VERSION` file in a feature pull request. Raising it freezes the current release
  and starts a new one, and that is a separate, deliberate commit.

## Reporting security problems

Do not open a public issue. Use private vulnerability reporting, described in
[SECURITY.md](SECURITY.md).

## Releases and the Homebrew cask

`docs/RELEASING.md` is the checklist. In short: every push to `main` re-publishes the release for
the version in `VERSION`; to start a new version, raise `VERSION`, write the section in both
changelogs, push. `Casks/andromac.rb` resolves the current build from the release API, so it
needs no edit per release; anything in `Casks/` must pass `brew style Casks/*.rb`, which CI runs.
