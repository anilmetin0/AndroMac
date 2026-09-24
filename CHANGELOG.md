# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `## <version>` section matching the `VERSION` file is the notes of that stable release.
New entries go under `## Unreleased`, which becomes the next version's section when `VERSION` is
raised. Betas list their commits instead.

## Unreleased

## 1.1.0 - 2026-09-24

### Added

- **Your phone's screen on the Mac.** Press the mirror button on the phone's card and its screen
  opens in a window, with mouse, keyboard and sound. It runs over Wireless debugging or a USB
  cable, powered by [scrcpy](https://github.com/Genymobile/scrcpy) 4.1, which now comes inside
  the Mac app. The panel walks you through the one-time setup and can open the right setting on
  the phone for you. If adb is already installed on the Mac, AndroMac uses that one. Settings →
  Screen mirroring has sound, screen off, stay awake and a resolution cap.
- **Updates you can read, and that install themselves.** Before an update installs, a window
  shows what changed, folded to a few lines until you open it. With **Install updates
  automatically** on (the default), the Mac installs once nothing is open or running, and the
  phone once you leave the app, on Wi-Fi only. The
  phone installs on its own on Android 12 and later; older phones ask first. A Mac
  installed with Homebrew updates through `brew upgrade`. **Beta updates** follows the test
  builds published between releases.
- **Pictures in notifications.** A photo in a chat message, a notification's big picture or the
  sender's avatar comes along with the notification and shows as its thumbnail on the Mac, next
  to the app's own icon. Only for apps set to Full, only when the picture changes, and at most
  96 KB.
- **Links open from the notification.** When a notification carries a web address, the Mac
  notification has an Open link button, and the history and the panel show one next to it.
- **The project one tap away.** The GitHub mark next to the version, in Settings on the phone
  and Settings → General on the Mac, opens the repository; the Mac's Help menu adds Report a
  Problem.
- **Reset AndroMac.** Settings on both apps can erase everything the app keeps and start over.
- **Pick your Mac.** With several Macs running AndroMac on the same network, Pair asks which one.
- **Ready for Android 17.** Android 17 asks before an app may talk to devices on your network.
  AndroMac now asks for that permission and lists it as required on the Permissions card.

### Changed

- **A cleaner Mac panel.** Each phone's battery shows once instead of three times, spacing is
  tighter, and the controls sit in one row of buttons with a menu for the rest. On macOS 26 and
  later the panel, buttons and window use Liquid Glass. The window has a single sidebar for the
  histories and every settings page, and ⌘, opens Settings.
- **A Material 3 phone app.** New colours, cards, switches, buttons and dialogs, following your
  wallpaper's colours on Android 12 and later.
- **A simpler phone app.** Settings has its own screen behind the button in the top bar. The
  connection guide disappears once you are paired and stays one tap away under the info button.
  The status names the Mac you are connected or connecting to, and pairing shows the Macs the
  phone can see. A new clipboard history lists the last 20 texts sent or received, kept in memory
  only.
- **One signing certificate for the Mac app.** Release builds are now signed with AndroMac's own
  self-signed certificate instead of ad-hoc. They are still not notarized, so the first-launch
  step stays, and the Keychain can ask once after an update; answer **Always Allow**.
- **One AndroMac at a time.** Opening a second copy brings up the one already running.
- **Releases.** Each version has one stable release, and the builds in between are published as
  betas. Ordinary pushes never rebuild the stable release. Only a manual stable run or a commit
  with `[stable]` in its message re-publishes it, which moves its tag.
- **Easier on the battery.** The phone looks for the Mac only on Wi-Fi or Ethernet, and only on
  the network where it last found it. It goes quiet while the Mac sleeps, holds battery updates
  while the screen is off, skips repeated notifications, and ignores clipboard requests with the
  screen off. The Mac stops watching the clipboard while it is locked or asleep, and wakes up
  less often.
- **Encrypted history.** The notification and clipboard history on the Mac is now encrypted with
  a key tied to the Mac's identity in the Keychain. A 1.0 history is converted the first time
  1.1 opens it.
- **Pairing prompts default to Reject** on the Mac, since they can pop up on their own whenever
  something on the network knocks.

### Fixed

- A notification an app posts in two steps, the text and then the sender's photo, arrives once
  and whole instead of showing half of it first. The replay after a reconnect updates a
  notification in place and keeps its time, and a history row whose text grew no longer shows
  half a line until it is scrolled.
- Clearing the notification or clipboard history on the Mac no longer crashes the app.
- Mac notifications show AndroMac's icon instead of a blank one. The icon now also ships as an
  asset catalog, and an update swaps the app in one step, so the system never sees a
  half-copied app without an icon.
- In the Mac panel, a notification's picture shows on its own, without a grey plate behind it,
  and an offline phone's More button sits on the hint line instead of a row of its own.
- With several phones connected, files, notification replies, dismissals and media controls went
  to every phone instead of the right one. A second phone could also rename the first, and a
  stranger's pairing prompt could show a paired phone's name.
- A phone that was paired with your Mac could treat someone else's Mac on the same Wi-Fi as
  its own and warn that the key had changed. It now skips other Macs quietly.
- The Mac showed the phone's model code, such as "SM S926B", instead of its name.
- In the Mac window, clicking a page could shift the sidebar under the title bar, the ⋯ menu on
  a phone's card did not open, and Quit took two seconds.
- A phone that reconnected in the middle of a file transfer left the transfer stuck.
- Forgetting one phone on the Mac disconnected all of them.
- The phone could redial nonstop when the Mac hung up right after connecting.
- Any change to any Android system setting was sent to the Mac. Now only the ringer, volume and
  Wireless debugging are.
- Two messages sent at the same moment could arrive out of order and drop the connection.
- The Mac could end up listening twice after Try again or unpairing, and a locked Keychain at
  login made phones report a changed key.

### Security

- Phones were told apart by a short 32-bit fingerprint, which a paired device could brute-force
  to take another phone's place. The full key hash is used now.
- A phone forgotten in the middle of a handshake could keep a hidden session. Trust is checked
  again once the handshake ends.
- The phone ran notification actions the Mac asked for even on apps set to Title only or Off.
- A file name could hide its real extension behind Unicode direction marks. Both sides strip them
  now, and on Android a received APK or unknown file opens Downloads rather than the file itself.
- On Android 10 to 12L, "Never send sensitive content" missed the marker password managers set.
- The updaters could match the wrong line of the checksum file. They now need the exact file
  name, and on Android the installer accepts only this app.
- App icons are requested from, and accepted from, only the phone that sent the notification.

## 1.0.0 - 2026-09-07

The first public release. Your Android phone and your Mac talk directly over your own network:
no server, no account, and no third-party libraries on either side.

### Added

- **Battery.** The phone's level, charging state and temperature, with an optional percentage in
  the menu bar and a warning when it runs low.
- **Clipboard, both ways.** Copy on the Mac and it lands on the phone, automatically or when you
  press the button. Opening the Mac panel asks the phone for its clipboard, and the Quick Settings
  tile, the notification button and the share sheet send it too. Anything a password manager
  marks as sensitive stays where it is. The Mac keeps the last 50 entries, searchable.
- **Notifications.** Phone notifications show up in Notification Center with the app's icon.
  Reply, run actions and dismiss from the Mac, and dismissing on one side clears the other. Pick
  Full, Title only or Off per app. The filtering happens on the phone, so Off means nothing is
  sent at all. The Mac keeps the last 200, searchable, and puts one-time codes on a copy button.
- **Media and phone controls.** See what is playing and skip, pause or play from the Mac. Set the
  ringer and media volume, send a test notification, or make a lost phone ring for up to 30
  seconds.
- **Files.** Send from the phone's share sheet, or drop files on the Mac panel. The receiver says
  yes first unless you turn on auto-accept, every file is checked against SHA-256, and nothing is
  ever opened for you.
- **Several phones.** Pair more than one Android with the same Mac. Each gets its own tab and its
  own clipboard switch, and can be disconnected on its own.
- **Updates.** Both apps check GitHub at most once a day, verify the download against the
  published checksum, and install it themselves. One switch turns this off. The Mac app is also
  on Homebrew and the APK on Obtainium.
- **Easy on the battery.** The phone runs no timer of its own: the Mac checks the connection every
  240 seconds and the phone only answers. Settings → Metrics on the Mac shows how much traffic
  that really is.
- **English and Turkish** in both apps. A new language is one file per platform.

### Security

- Pairing uses a Noise-KK-style handshake over P-256 with AES-256-GCM. You confirm a 6-digit code
  on both screens, and it is built so that nobody on the network can forge a match offline, the
  weakness KDE Connect fixed in 2025.
- After pairing, each side pins the other's key. A changed key is refused and reported, never
  quietly accepted.
- Every session uses fresh keys, so recorded traffic cannot be decrypted later, and a replayed
  message closes the connection.
- The Mac limits unverified connections and pairing prompts, so a stranger on your Wi-Fi cannot
  knock a paired phone offline or flood you with prompts.
- Keys live in the macOS Keychain and the Android Keystore. Histories stay on the Mac and are
  deleted when you unpair. Logs never contain message content.
- The crypto is written twice, in CryptoKit and in JCE, and two scripts check on every push that
  both halves agree.
