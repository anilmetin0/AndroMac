## What this changes

<!-- One or two sentences. Link the issue it closes, if there is one. -->

## Checklist

- [ ] Builds on both sides: `macos/build.sh` and `./gradlew :app:assembleDebug`.
- [ ] `./verify-crypto.sh` and `./verify-handshake.sh` pass, if this touches crypto, the handshake, framing or the message set.
- [ ] Unit tests pass: `(cd macos && swift test)` and `./gradlew :vectors:test`. New pure logic (parsers, version ordering, filters) comes with a test.
- [ ] `docs/PROTOCOL.md` updated in this PR, if the wire format or the message set changed.
- [ ] The energy contract in `docs/ENERGY.md` still holds: no periodic timer on the phone, no polling, no wakelock, filtering at the source. If this adds a wakeup, the description says why.
- [ ] No new third-party dependency, or the description argues why the platform cannot do it.
- [ ] User-visible strings go through `res/values/strings.xml` or `Localizable.strings`, and `macos/scripts/update-strings.sh --check` passes.
- [ ] `CHANGELOG.md` and `CHANGELOG.tr.md` have an entry under the unreleased version, if this is user-visible.

## Testing

<!-- What you ran, and on which devices or macOS/Android versions. -->
