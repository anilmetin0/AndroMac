# Security policy

AndroMac pairs two devices with a Noise-KK-style handshake over P-256 and carries every
application message inside AES-256-GCM. A flaw in that path is the one class of bug that can
expose a user's notifications, clipboard or identity key, so it is handled privately.

## Supported versions

| Version | Supported |
|---|---|
| The latest build of the current version (the `v<VERSION>` release) | Yes |
| Anything older | No |

Fixes land in the next build of the current version. There are no backports to older versions.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting:
**[Report a vulnerability](https://github.com/anilmetin0/AndroMac/security/advisories/new)**
(Security → Advisories → Report a vulnerability on the repository).

There is no email address for this on purpose. Private advisories keep the report, the discussion
and the fix in one place, and let you be credited when it is published.

Do not open a public issue, a discussion or a pull request for a vulnerability before it has been
fixed and released.

### What to include

- Which side is affected, Android or macOS, and the version, shown in both apps as
  `1.0.0 (12 · abc1234)`.
- What an attacker has to be able to do first: be on the same Wi-Fi network, hold the phone,
  control a paired Mac, run code on either device.
- Steps to reproduce, or a proof of concept. A failing case for `verify-crypto.sh` or
  `verify-handshake.sh` is the most useful form a protocol report can take.
- The impact you believe it has.

### What to expect

| Step | Target |
|---|---|
| Acknowledgement of your report | 5 days |
| First assessment, accepted or not | 14 days |
| Fix released for an accepted report | 90 days |
| Public advisory | With the fix, or at 90 days |

This is a spare-time project with no security team behind it, so those are targets rather than
guarantees. If a report is still unfixed at 90 days, publishing it is your call and there will be
no complaint about it.

## Scope

In scope:

- **The protocol.** The handshake, key agreement, key derivation, framing, nonce handling,
  replay protection, and the length and type limits the receiver enforces. See
  [docs/PROTOCOL.md](docs/PROTOCOL.md).
- **Pairing and trust.** The SAS comparison, key pinning, anything that would let a third device
  be pinned silently, take over an established session, or downgrade a pinned key back to first
  contact.
- **Storage.** The identity key in the macOS Keychain and in the Android Keystore, the pinned
  peer key, and the notification and clipboard histories on the Mac.
- **Data leaving a device.** Anything that sends content the user asked to keep local: an app on
  the Off tier, a title-only app whose body leaves the phone, a clipboard flagged sensitive.
- **The build and release path.** The workflow in `.github/workflows/build.yml` and
  `scripts/setup-android-signing.sh`.

Out of scope:

- An attacker who already has code execution, root or physical unlocked access to either device.
- Denial of service on the local network. Anyone on your Wi-Fi can already flood it, and the
  design accepts a dropped connection as normal, since it reconnects on a backoff ladder.
- The absence of macOS notarization. The app is ad-hoc signed, which is documented in the README
  and is a distribution choice, not a defect.
- Traffic analysis that reveals that two devices are talking, or roughly how often. The frame
  length is visible on the wire by design.
- Findings from an automated scanner with no demonstrated impact.

## Design notes a report should account for

- Both sides implement the same crypto independently, CryptoKit on macOS and JCE on Android.
  `verify-crypto.sh` compares them vector by vector and `verify-handshake.sh` runs the real
  session code over loopback. Run both before concluding that one side is wrong.
- The Android identity key is stored wrapped, with an AES-256-GCM key that cannot leave the
  Android Keystore, but it is unwrapped into process memory for the key exchange. That is the
  known ceiling of doing P-256 in software rather than inside the keystore, and it is documented
  rather than a finding on its own. A way to reach that memory from another app is a finding.
- The Bonjour TXT record carries no key material, only a device name and the protocol version.
  The pin decision is made only from the key proven during the handshake.
