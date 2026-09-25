# Releasing

`.github/workflows/build.yml` does everything described here. A maintainer keeps the changelogs
current and raises `VERSION` when a version is ready. The pipeline is the same on
every push and pull request; only a push to `main` publishes at the end.

## What every run does

1. `scripts/verify-crypto.sh`: the CryptoKit and JCE implementations produce identical vectors.
2. `scripts/verify-handshake.sh`: the real Swift responder and Kotlin initiator complete a
   session over loopback.
3. `swift test` and `./gradlew :vectors:test`: the unit tests on both sides.
4. `./gradlew :app:lintDebug`: Android lint.
5. `macos/scripts/update-strings.sh --check`: every localization key exists in every language.
6. `brew style Casks/*.rb`, and the cask's version equals `VERSION`.
7. The macOS bundle and the Android APK are built and uploaded as workflow artifacts.

A pull request, or a push to any other branch, stops there. A push to `main` continues to the
release job, on one of two channels.

## Two channels

| | Stable | Beta |
|---|---|---|
| When | The first push to `main` after `VERSION` changes, a push whose commit message contains `[stable]`, or a manual run with channel `stable` | Every other push to `main` |
| Tag | `v<VERSION>` | `beta-<BUILD>-<sha>` |
| Title | `AndroMac <VERSION>` | `AndroMac <VERSION> beta <BUILD>` |
| Marked | Pre-release until promoted, then Latest | Pre-release, never latest |
| Assets | `AndroMac-<VERSION>-macOS-arm64.dmg`, `AndroMac-<VERSION>-android.apk`, `SHA256SUMS.txt` | `AndroMac-beta-<BUILD>-macOS-arm64.dmg`, `AndroMac-beta-<BUILD>-android.apk`, `SHA256SUMS.txt` |
| Notes | The `## <VERSION>` section of `CHANGELOG.md`, then the features and fixes since the previous version's tag | The features and fixes since `v<VERSION>` |
| Kept | Forever | The newest five |

Ordinary pushes never rebuild a stable release. A manual run with channel `stable`, or a push
whose commit message contains `[stable]`, re-publishes it from that commit and moves the
`v<VERSION>` tag there.

A stable release goes out as a pre-release, so the apps with **Beta updates** on (Settings →
Updates) get it first. Once it holds up, promote it:

```bash
gh release edit v<VERSION> --prerelease=false --latest
```

From then on `/releases/latest`, Obtainium's default settings and the apps' stable channel see
it. Until then they keep offering the previous version. The Homebrew cask is the exception: it
follows `VERSION` in the repository, so `brew install` already fetches the new DMG.

The notes are in English only; `CHANGELOG.tr.md` is the Turkish changelog in the repository. The
commit list has New (`feat`) and Fixed (`fix`), with the scope shown as the platform
(`fix(macos):` becomes **Mac:**); docs, CI and other housekeeping commits are left out.

Every release body ends with the install line, which carries the build and the commit in an
HTML comment the release page does not show: `<!-- Build <N> · commit <sha> -->`. The apps read
the build number from it. The build number is the
workflow run number, which is also the Android `versionCode`, so a newer build always installs
over an older one. Inside the apps the version reads `<VERSION> (build · commit)`; a beta after
1.1.0 reads `1.1.0 (57 · abc1234)`. Local builds show build 1, commit `local`.

A stable release fails, and publishes nothing, if `CHANGELOG.md` lacks a `## <VERSION>`
section. The header may carry a date (`## 1.2.0 - 2026-10-01`); only the version is matched.

## Releasing a version

1. Pick the version. Patch for fixes, minor for features, major for a protocol break that makes
   old and new builds refuse each other.
2. Rename `## Unreleased` to `## <version> - <date>` in `CHANGELOG.md` and `CHANGELOG.tr.md`.
3. Write the version into `VERSION` (one line, no `v`) and into `Casks/andromac.rb`.
4. Commit as `chore(release): <version>` and push to `main`. That push publishes the stable
   release as a pre-release; the pushes after it publish betas until the next version.
5. Watch the run with `gh run watch`, then check the release page.
6. Once it works on real devices, promote it with the `gh release edit` line above.

To rebuild a stable release in place, for example after a broken asset, put `[stable]` in the
commit message of the push, or run the workflow on `main` from the Actions tab with channel
`stable`.

## Homebrew and Obtainium

- `Casks/andromac.rb` carries the version and downloads
  `releases/download/v<VERSION>/AndroMac-<VERSION>-macOS-arm64.dmg`. It changes with `VERSION`,
  and CI fails when the two disagree. The checksum is not pinned (`sha256 :no_check`);
  `SHA256SUMS.txt` on the release page carries it. The cask declares `auto_updates true`: the
  app updates itself, through `brew upgrade` when Homebrew installed it.
- Obtainium keys on the tag name, which changes once per version, so it sees each stable release
  without extra options. Its "include prereleases" option adds the betas.

## Signing

- Android: the APK is signed with the keystore in the `ANDROID_*` repository secrets, created
  by `scripts/setup-android-signing.sh`. Without the secrets the APK is signed with a debug key
  that changes every run, and Android refuses to upgrade an installation signed with a
  different key.
- macOS: the bundle is signed with the self-signed certificate in the `MACOS_SIGNING_*`
  secrets, created by `scripts/setup-macos-signing.sh`. It is not a Developer ID certificate, so
  the app is not notarized and the first-launch step in the README stays. Without a Developer ID
  the Keychain can still ask once after an update, and one "Always Allow" answers it. Without the
  secrets the build is signed ad-hoc.

Both scripts keep their key and its password in `~/.andromac/` on the machine that ran them and
never in the repository. Back that directory up: a lost Android key closes the upgrade path, and
a new Mac certificate means one more Keychain prompt for every user.

## If something goes wrong

- If the release job failed: a stable re-publish deletes the old release before creating the new
  one, so a failure after that point leaves no release for the version until the next
  successful run. Fix the cause, then re-run the workflow.
- If the changelog section is missing, the stable job stops before touching the release; add the
  section and run it again.
- If the notes are wrong, edit the release on GitHub, or fix the changelog and re-publish.
