## What this changes

<!-- One or two sentences. Link the issue it closes, if there is one. -->

## Checklist

- [ ] The branch is based on `main`, and the commits follow Conventional Commits (`feat:`, `fix:`, `docs:`, ...).
- [ ] Both apps build: `macos/build.sh` and `android/gradlew -p android :app:assembleDebug`.
- [ ] Unit tests pass: `(cd macos && swift test)` and `android/gradlew -p android :vectors:test`. New pure logic comes with a test.
- [ ] If this touches crypto, the handshake, framing or the message set: `scripts/verify-crypto.sh` and `scripts/verify-handshake.sh` pass, and `docs/PROTOCOL.md` is updated.
- [ ] If this adds or changes user-visible strings: `macos/scripts/update-strings.sh --check` passes.
- [ ] The energy contract in `docs/ENERGY.md` still holds. If this adds a wakeup on the phone, the description says why.
- [ ] No new third-party dependency, or the description explains why the platform cannot do it.
- [ ] If users will notice this: an entry under `## Unreleased` in `CHANGELOG.md` and `CHANGELOG.tr.md`.

## Testing

<!-- What you ran, on which phone and Android version, and which macOS version. Give the app versions as the apps show them, for example 1.1.0 (42 · e105e58). -->
