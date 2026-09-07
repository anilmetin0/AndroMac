# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `## <version>` section that matches the `VERSION` file is the release notes of the rolling
build for that version. It is edited in place while that version is in development; a new
version gets a new section.

## 1.0.0 — 2026-09-07

First public release. Android and macOS talk over the local network only, with no server, no
account and no third-party library on either side.

### Added

- **Pairing.** Noise-KK-style handshake over NIST P-256, HKDF-SHA256 key derivation and
  AES-256-GCM framing. A 6-digit code appears on both screens. It is bound to the session
  transcript and to a nonce from each side, exchanged under a commitment, so nobody on the
  network can grind it offline until both screens agree, the class of weakness KDE Connect fixed
  in 2025 (CWE-222). Both long-term keys travel encrypted: the Mac's under the ephemeral secret,
  the phone's only after the Mac's key matched the pin and only readably by that Mac. The Bonjour
  record carries no key, so a listener cannot tell which phone is present. Once the code is
  confirmed the peer's static public key is pinned; a changed key is rejected and reported, never
  re-pinned silently. Rejecting a pairing code on the Mac mutes that key for 1, 2, 4 … 60
  minutes.
- **More than one phone.** Several Androids can be paired with one Mac and be connected at the
  same time. Pairing, connecting and disconnecting are separate: a paired phone that is switched
  off is Offline, not unpaired, and it reconnects on its own with a 1, 2, 5, 15, 60, 300 second
  backoff. The panel lists every device, expands on click, and each device can be paused or
  resumed without losing the pairing. A reinstalled phone arrives as a new device with a new
  code, and the old entry stays visible until you remove it, rather than failing silently.
- **Clipboard targets per device.** With more than one phone paired, each one has its own
  "Send my clipboard here" switch, so a copy can go to one phone and not the other.
- **Battery.** Level, charging state and temperature from the phone. Optional percentage in the
  macOS menu bar, a bar in the panel, and a one-time warning when the level drops below 15%.
- **Clipboard, Mac to phone.** Automatically as you copy, or only when you ask: the paperplane
  button in the menu bar panel sends the current clipboard on demand. Settings → Clipboard holds
  the choice. Either way a silent notification carrying a Paste action arrives as a second route
  past manufacturer restrictions. A clipboard a password manager marked concealed
  (`org.nspasteboard.ConcealedType`) is never sent, matching what the phone already does.
- **Clipboard, phone to Mac.** Opening the Mac panel asks the phone for its clipboard, and the
  phone answers through an invisible activity that takes focus for a moment — with "Display over
  other apps" granted that is instant, otherwise the phone posts a notification with one button.
  The Quick Settings tile, the button on the ongoing notification and the share sheet still push
  it from the phone. Android does not allow background clipboard reads at all, so nothing in this
  direction happens without the phone answering.
- **Clipboard protection.** Text a password manager or OTP field marked with
  `ClipDescription.EXTRA_IS_SENSITIVE` never leaves the phone. On by default, and switchable.
- **Clipboard history on the Mac.** The last 50 entries in both directions, searchable, click to
  copy, right-click to send back to the phone or delete.
- **Notification mirroring.** Notifications reach macOS Notification Center with the app's own
  icon. Actions, including inline reply, are triggered from the Mac, and dismissal is synced in
  both directions.
- **Per-app notification tiers.** Full, Title only, or Off, set from either device and applied on
  the phone. On Off the radio never wakes for that app; on Title only the body never leaves the
  phone.
- **Notification noise filter.** Group summaries, ongoing notifications, foreground-service
  notifications, local-only notifications and silent channels are dropped before sending. An
  option restricts mirroring to times when the phone is locked.
- **Notification history on the Mac.** The last 200 entries, searchable, stored only on the Mac.
- **Verification codes from notifications.** When a mirrored notification carries a one-time
  code, the panel shows the code itself on a copy button. Copying it puts it on the Mac clipboard
  without sending it back to the phone and without storing it in the clipboard history.
- **Media.** Title, artist and app of the track playing on the phone, with previous, play/pause
  and next from the Mac. Sent only on change, with no progress bar.
- **Phone controls from the Mac.** The panel sets the phone's ringer (ring, vibrate, silent) and
  its media volume, and can send a test notification that travels the whole mirroring chain and
  comes back — a permission problem on the phone shows up as nothing arriving, which is the
  useful answer. Silencing needs Do Not Disturb access on the phone; the phone reports whether it
  has it, and the Mac disables the button rather than sending a command that can only fail.
- **Permission banner on Android.** While the notification permission or notification access is
  missing, a dismissible banner sits at the top of the main screen and opens the right settings
  screen when tapped. The notification permission is requested at launch, and notification
  access — which has no runtime dialog — is offered once, with its reason.
- **Find my phone.** The Mac rings the phone at alarm volume with vibration for at most 30
  seconds. It stops on Found it, on a second request, or on its own.
- **Connection guide.** Both apps show which step is stuck rather than a generic failure. The
  phone has a live diagnostics screen, and the Mac links straight to the Local Network permission.
- **Metrics on the Mac.** Uptime, messages sent and received, messages per hour, traffic,
  reconnect count and the most frequent message types, so the energy claim can be checked rather
  than trusted.
- **Launch at login** on macOS, and start on boot on Android once paired.
- **App icon.** Two opposing arrows, out and back, on a deep navy plate: the same drawing on both
  platforms, generated from code at build time so the repository still keeps no binary image of it.
- **English and Turkish** throughout both apps. Android uses the per-app language picker;
  macOS has System, English and Turkish in Settings. A new language is one file per platform and
  no code change.
- **Two verification scripts.** `verify-crypto.sh` compares the CryptoKit and JCE implementations
  vector by vector, and `verify-handshake.sh` runs the real session code from both platforms
  against each other over loopback. Both run in CI on every push.
- **File transfer.** Share any file from the phone's share sheet, or use Send file… and
  drag-and-drop on the Mac panel. The receiver is asked before anything is written, or accepts
  automatically when you turn that on, which then applies to every paired phone. Files go to Downloads, are sent in
  512 KiB chunks over the existing encrypted session with a bounded 8-chunk window (4 MiB in
  flight, one ack per chunk), verified
  against SHA-256 before they get their final name, sanitized on arrival, and never opened for
  you. The Mac marks them with the browser-download quarantine flag. Settings → Files on both
  apps.
- **Updates, checked and installed in the app.** On by default on both sides, with the switch in
  Settings → Updates. The app asks the GitHub releases API at most once a day, only when it is
  opened, and offers what it finds once per release: Install now, Later, or Skip this version.
  Installing downloads the release asset, verifies it against the `SHA256SUMS.txt` published with
  that release, and only then replaces the app — the Mac swaps its own bundle and restarts, the
  phone hands the APK to Android's installer, which asks for confirmation and enforces the
  signature. A missing or mismatched checksum stops the update. A newer build is a greater
  version or the same version built from a different commit.
- **QR code for the APK.** Settings → Updates draws a QR code for the releases page, so the
  phone build can be installed without typing a URL. It is drawn locally from a constant and
  fetches nothing, so it works with the update check switched off.
- **Homebrew.** `brew tap anilmetin0/andromac https://github.com/anilmetin0/AndroMac`, then
  `brew install --cask andromac`. The cask resolves the current build from the release API, so
  it upgrades with `brew upgrade --cask --greedy-latest andromac`.
- **Obtainium.** The release APK is signed with one key across versions, so updates install in
  place; Obtainium keys on the tag name, so it only notices a new build of the same version when
  its "release date as version string" option is on.
- **Compared with other tools.** The README's trust-model section sets AndroMac side by side
  with Syncthing, LocalSend, KDE Connect, Quick Share, AirDrop, Magic Wormhole and Blip, with
  the advisories that shaped each decision.
- **Unit tests** for version ordering, the update check, file-name sanitization and chunk math
  on both sides, run in CI.

### Changed

- **Permissions on the phone.** The Setup section is now a Permissions card that is always on the
  main screen: one line saying "All granted" or how many are missing, the missing ones listed
  underneath, and a Permissions screen behind it that lists all five with Granted or Not granted
  and Required, Recommended or Optional.
- **Connection screen on the phone.** State, the Mac's name and last address, a Reconnect
  automatically switch, Connect now, and Forget this Mac (moved here from the ⋮ menu).
- **Reconnecting.** The backoff ceiling is 60 s while the screen is on and 300 s when it is off,
  and turning the screen on triggers an attempt at once. The ongoing notification no longer
  shows a countdown; it says Waiting for Mac.
- **Phone to Mac clipboard.** Opening AndroMac on the phone sends the current clipboard to the
  Mac, once per copy, on top of the existing routes.
- **Device tabs on the Mac.** With more than one phone paired, the panel shows them as tabs
  across the device card instead of expandable rows.
- **Settings on the Mac.** A sidebar with General, Sync, Clipboard, Notifications, Files,
  Devices, Permissions, Network, Updates, Metrics and Privacy. Sync gains a low-battery threshold
  (10, 15, 20 or 30 %), Notifications a sound switch, and Permissions shows the state of
  Notifications, Local Network and Keychain access with a button to the matching System Settings
  pane. The panel warns in one line while macOS notifications are off for AndroMac.
- **Motion.** Detail screens on the phone slide in and out; on the Mac, switching a device tab, a
  window tab or a settings section fades. Corner radii on the Mac come from one scale.
- **Menu bar icon.** Right-click opens a menu with Open AndroMac, Settings and Quit.
- **Release files.** One DMG for Apple Silicon, `AndroMac-<version>-macOS-arm64.dmg`, and one
  APK for every phone, `AndroMac-<version>-android.apk`. The release title is `AndroMac <version>`;
  both update checks read the commit from the tag's target instead. The Mac updater installs from
  the DMG.

### Fixed

- **Display over other apps** never worked: the app did not declare `SYSTEM_ALERT_WINDOW`, so it
  was missing from Android's list and the check always failed.
- Quitting the Mac app took two seconds every time: the shutdown waited on the main thread
  while also trying to hop to it. It is immediate now.
- The menu bar could freeze while a Keychain prompt was open, because the device list shared a
  lock with the identity read. They have separate locks now.
- The main screen no longer flickers while looking for the Mac: repeated identical link states
  are no longer re-broadcast.

### Security

- Ephemeral keys per session give forward secrecy. Nonces are per-direction counters, so a replay
  closes the connection and nonce reuse cannot happen.
- No application message is processed before the handshake completes. macOS enforces a 10-second
  handshake timeout, a cap on concurrent unverified connections and a rate limit on the pairing
  prompt, and it rejects peers outside private address ranges. An established session is given up
  only after a new connection has finished its handshake, so another device on the network cannot
  knock a paired phone offline.
- Frames are capped at 1 MiB, and the receiver enforces its own length limits on every field
  rather than trusting the sender.
- The identity key lives in the macOS Keychain and, on Android, wrapped with a non-exportable
  AES-256-GCM key held in the Android Keystore.
- Histories are stored only on the Mac and are deleted when the pairing is removed. Logs never
  carry message content or key material.
- The workflow runs with read-only permissions except for the release job. Dependabot watches the
  actions and the Gradle plugins weekly.
