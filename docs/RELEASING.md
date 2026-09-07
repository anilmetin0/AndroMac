# Releasing

Everything here is done by `.github/workflows/build.yml`. A human does two things: keeps the
changelogs current, and raises `VERSION` when a new version starts. The pipeline is the same on
every push and pull request; only a push to `main` publishes at the end.

## What every run does

1. `verify-crypto.sh`: the CryptoKit and JCE implementations produce identical vectors.
2. `verify-handshake.sh`: the real Swift responder and Kotlin initiator complete a session over
   loopback.
3. `swift test` and `./gradlew :vectors:test`: the unit tests on both sides.
4. `macos/scripts/update-strings.sh --check`: every localization key exists in every language.
5. `brew style Casks/*.rb`: the Homebrew cask lints clean.
6. The macOS bundle and the Android APK are built and uploaded as workflow artifacts.

A pull request stops there. A push to `main` continues to the release job.

## The rolling release

AndroMac is in development and stays at the version in `VERSION` until a human raises it. There
is no stable/dev split: every push to `main` re-publishes one release for the current version.

| | |
|---|---|
| Tag | `v<VERSION>`, deleted and recreated at the pushed commit on every run |
| Title | `AndroMac <VERSION>`, e.g. `AndroMac 1.0.0`. The commit is the tag's target (`target_commitish` in the API), which is what both update checks read |
| Assets | `AndroMac-<VERSION>-macOS-arm64.dmg` (Apple Silicon only), `AndroMac-<VERSION>-android.apk` (one APK, no native code), `SHA256SUMS.txt`. No commit in the names, so a rebuild keeps the same file names |
| Notes | the `## <VERSION>` section of `CHANGELOG.md`, the `CHANGELOG.tr.md` one folded below it, then `## Changes in this build` (the commits since the previous build of this version, or "First build" on the first one), the install links and a build/commit/signing footer |

The release is marked latest and is never a pre-release. The job fails, and publishes nothing, if
either changelog lacks a `## <VERSION>` section. The section header may carry a date
(`## 1.0.0 — 2026-09-04`); only the version is matched.

Inside the apps the version reads `<VERSION> (build · commit)`: the version from the file, the
build is the workflow run number (also the Android `versionCode`, so each build installs over the
previous one), the commit is the 7-character sha. Local builds show `<VERSION>`, build 1,
commit `local`.

## Starting a new version

1. Pick the version. Patch for fixes, minor for features, major for a protocol break that makes
   old and new builds refuse each other.
2. Add a `## <new version>` section to `CHANGELOG.md` and `CHANGELOG.tr.md` (a date after a dash
   is fine). Both must exist or the release job refuses to publish.
3. Write the version into `VERSION`, one line, no `v`.
4. Commit and push to `main`. The old `v<old version>` release stays where it is, frozen at its
   last build; the new tag starts rolling from this commit.
5. Watch the run: `gh run watch`, then check `https://github.com/anilmetin0/AndroMac/releases/latest`.

Nothing is pushed to any store or third-party index. Obtainium and Homebrew both read the release
page directly.

## Homebrew and Obtainium

- `Casks/andromac.rb` uses `version :latest` and finds the current DMG on the latest release
  through the GitHub API, so it needs no edit when a build or a version changes. The checksum is
  not pinned (`sha256 :no_check`) because every push changes the DMG; `SHA256SUMS.txt` on the
  release page carries it. Users pick up a newer build with
  `brew upgrade --cask --greedy-latest andromac`.
- Obtainium keys on the tag name. While a version is rolling the tag does not change, so
  Obtainium will not notice new builds unless its "release date as version" option is on. The
  in-app update check (Settings → Updates) compares the commit and does notice.

## Signing

The APK is signed with the keystore in the `ANDROID_*` repository secrets, created by
`scripts/setup-android-signing.sh`. The script keeps the keystore and its password in
`~/.andromac/` on the machine that ran it and never in the repository. Back that directory up.
Without the secrets the APK is signed with a debug key that changes every run, and Android will
refuse to upgrade an installation signed with a different key.

The macOS bundle is signed ad-hoc. Homebrew therefore cannot promise Gatekeeper acceptance; the
cask says so in its caveats and the README shows the `--no-quarantine` flag.

## If something goes wrong

- **Release job failed.** The job deletes the old release before creating the new one, so a
  failure after that point leaves no release for the version until the next successful push.
  Fix the cause if there is one, then re-run the workflow from the Actions tab or push again.
- **Missing changelog section.** The job stops before touching the release; add the section and
  push.
- **Wrong notes.** Edit the release on GitHub, or fix the changelog and push: the next run rewrites
  the notes anyway.
