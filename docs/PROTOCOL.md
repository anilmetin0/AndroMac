# AndroMac wire protocol v3

This document is the reference for the protocol. The Android and macOS apps are both written
against it.

## 1. Discovery

- macOS is the server. It advertises an `_andromac._tcp` Bonjour service on a dynamic port
  (port 0, so the OS assigns one).
- TXT records: `n=<device name>`, `v=3`. No key material: the Mac's static key is only sent
  inside the handshake (§2), so a Bonjour browse does not identify the machine beyond its name.
- Android is the client. It browses with `NsdManager`.
- Android stores the last successful `ip:port` and tries that first. It starts an mDNS browse only
  if that fails.
- The browse stops as soon as a connection is established, because continuous mDNS scanning
  costs battery.

Sync traffic never leaves the local network: macOS rejects any peer outside the private address
ranges (§3). The only connections that leave the LAN are the update check (one HTTPS GET to
api.github.com, `releases/latest`, or `releases?per_page=10` on the beta channel), the update
download from github.com, and `brew upgrade` on a Mac that Homebrew installed, when a new version
installs.

## 2. Handshake

Noise-KK-like, over NIST P-256. Every device has a long-term (static) P-256 key pair.
`A` = initiator (Android), `B` = responder (macOS).

Keys are sent as 65 bytes in X9.62 uncompressed form (`0x04 || X || Y`).

Only the ephemeral keys travel in the clear. Each static key is sent encrypted, and the phone's
only after the Mac has proven to be the pinned one, so a passive listener sees two random
per-session keys and nothing else, and a stranger answering on the port never learns the
phone's identity key.

```
1. A -> B : [1 byte proto=3][65 byte e_pub_A]                                    (66 bytes)

h1     = SHA256( "AndroMac/v3" || e_pub_A || e_pub_B )
dh1    = ECDH(e_A, e_B)                                    # forward secrecy
k_ee   = HKDF( salt = h1, ikm = dh1, info = "AndroMac/v3 ee", 32 )
n_B    = 32 random bytes (kept secret by B for now)
c_B    = SHA256( "AndroMac/commit" || n_B )                 # B commits to n_B before it sees n_A
ct_B   = AES-GCM( k_ee, nonce=0, s_pub_B || c_B )          # 65 + 32 + 16 tag = 113 bytes

2. B -> A : [1 byte proto=3][65 byte e_pub_B][113 byte ct_B]                     (179 bytes)

dh3    = ECDH(e_A, s_B)                                    # authenticates B
k_es   = HKDF( salt = h1, ikm = dh1 || dh3, info = "AndroMac/v3 es", 32 )
ct_A   = AES-GCM( k_es, nonce=0, s_pub_A )                 # 65 + 16 tag = 81 bytes

3. A -> B : [81 byte ct_A]
```

A opens `ct_B`, validates `s_pub_B` as a curve point and checks its pin at this point. If a key
is pinned and `s_pub_B` differs from it, A closes the connection before message 3, so the phone's
static key is never shown to a peer it does not trust. Only the holder of `s_B`'s private key can
open `ct_A`, so the guarantee also holds against an active peer.

A peer that presents any other `proto` byte is rejected ("unsupported protocol version"). There
is no fallback because both apps ship together. The `hello` message (§5) carries `proto: 3` as well.

Both sides then compute:

```
dh2 = ECDH(s_A, e_B)      # authenticates A

transcript = SHA256( "AndroMac/v3" || e_pub_A || e_pub_B || ct_B || ct_A )
prk        = HKDF-Extract( salt = transcript, ikm = dh1 || dh2 || dh3 )
k_a2b      = HKDF-Expand( prk, "AndroMac a2b", 32 )
k_b2a      = HKDF-Expand( prk, "AndroMac b2a", 32 )
```

In the confirmation round each side encrypts `transcript` plus its own fresh 32-byte nonce with
its own direction key, then decrypts what the other side sent and checks it:

```
n_A = 32 random bytes
3b. A -> B : Frame( AES-GCM(k_a2b, nonce=0, transcript || n_A) )     # same flush as ct_A
4.  B -> A : Frame( AES-GCM(k_b2a, nonce=0, transcript || n_B) )
```

B checks that the first 32 bytes of message 3b equal `transcript`, and only then sends message 4.
A checks that the first 32 bytes of message 4 equal `transcript` and that
`SHA256("AndroMac/commit" || n_B) == c_B`, which proves B committed to this nonce in message 2.
If anything fails to decrypt, has the wrong length, or does not match, the connection is closed
immediately. This step catches a failed key agreement, an active MITM, and a responder that
tried to pick `n_B` after seeing `n_A`.

## 3. Trust (pairing, TOFU)

The SAS (Short Authentication String) is the 6 digits the user compares across the two screens. It
is bound to the session transcript (both ephemeral keys and both encrypted static keys, which also
covers B's commitment) and to both fresh nonces, so it is different on every connection attempt:

```
sas     = ( first 4 bytes of SHA256("AndroMac/SAS/v3" || transcript || n_A || n_B) as BE uint32 )
          mod 1_000_000
display = sas zero-padded to 6 digits
```

Both sides derive the code from the same attempt, so the two screens show the same digits, and a
retry produces a new code on both. What gets pinned is the peer's static public key, never the
code, so pairings made before v3 keep working.

v1 derived the code from the two static keys alone, and a code like that can be ground offline: an
active MITM on the LAN (a rogue Bonjour advertisement with the same name) holds one key pair toward
the phone and another toward the Mac, sees both real static keys in cleartext (v1 sent them in
message 1 and the TXT record), and keeps generating key pairs until the code on the phone's link
equals the code on the Mac's link. With 6 digits that is a birthday search of roughly a thousand key
generations, done before the user ever looks at the screens; the user then compares two matching
codes and pins the attacker. KDE Connect's 2025 advisory on its truncated verification codes
(CWE-222, the same class of flaw) is the concrete precedent. The v2+ construction is the Bluetooth
Numeric Comparison pattern: B must commit to `n_B` before it sees `n_A`, and A must reveal `n_A`
before it sees `n_B`, so neither side, and no one in the middle, can choose its input after all the
others are known. An attacker gets exactly one 1-in-a-million guess per attempt the user actually
sees.

- On first contact both sides show the code and the user confirms on both. After confirmation
  each side pins the other side's static public key and name permanently.
- On later connections the incoming static public key must be byte-for-byte identical to a
  pinned one, otherwise the connection is rejected. Nothing is ever re-pinned silently.
- The phone pins exactly one Mac, so a key that differs from the pinned one is a "key changed"
  warning, never a first contact, and tapping "Pair" does not drop the pin. The Mac pins a set of
  phones, so that state does not exist there: an unknown key is an unknown device and gets the
  ordinary first-contact prompt (see the multi-device bullet below).
- With other Macs on the network, the phone dials the Mac advertising the paired name first. A
  mismatching key from a Mac that advertises a different name is somebody else's Mac: it is
  skipped for the rest of the network session, with no warning. Only a mismatch under the paired
  name is a "key changed". While unpaired, Pair with two or more Macs in view asks which one.
- On first contact the connection is closed after the handshake; both sides show the SAS and
  wait for confirmation. On a phone-side mismatch the phone hangs up before message 3 and shows
  "key changed" without a code; the Mac shows that attempt's code. After
  confirmation the phone reconnects. If the Mac side is confirmed later than the phone side, the
  phone's first attempt is still rejected, and the phone retries on its backoff ladder (1, 2, 5 s
  and so on), so the user does not have to tap a second time.
- On the macOS side the handshake must finish within 10 s, and at most 4 unverified connections
  are held at once. The pairing prompt is shown at most once per 30 s. A key the user rejected in
  that prompt is muted for 1, 2, 4 and up to 60 minutes (doubling per rejection, cleared by an
  approval or a restart). An established session is given up only after a new connection's
  handshake has succeeded, so another device on the network cannot drop a paired session by
  opening a TCP connection. Connections from outside the private address ranges (not RFC 1918 /
  link-local / ULA) are rejected before the handshake.
- The Mac trusts a set of phones and the phone trusts one Mac. macOS pins a list of static public
  keys and will hold a session with each of them at the same time, keyed by the device ID (the
  full SHA-256 over its static public key, in hex). The 8-hex fingerprint is only for display.
  Android still pins exactly one Mac. Consequences on the macOS side:
  - There is no "the pinned key changed" state, because it can only be defined when there is
    exactly one pinned key. A key that is not in the set belongs to a device the Mac has not met,
    whether it is a new phone or one that was wiped and reinstalled, and both need the same fresh
    SAS approval. The approval protects the user; the label on the prompt does not.
  - A reinstalled phone therefore appears as a new device, and the old entry stays in the list
    until the user removes it. This is deliberate. KDE Connect instead fails the TLS connection
    with no message, which leaves a device listed as paired that never connects again and cannot
    be recovered inside the app.
  - Approving a phone never drops another. Unpairing removes one device and leaves the rest.
  - A paused device stays paired but is refused at the handshake. That is the only way to make a
    disconnect stick, because closing the socket only starts the phone's reconnect ladder.
- The Bonjour record carries no key; the phone makes its pin decision only from the key proven
  during the handshake.

## 4. Framing

After the handshake every message is:

```
[4 byte big-endian length N][N bytes ciphertext]
ciphertext = AES-256-GCM(key = k_<direction>, nonce = counter, aad = none, pt = UTF-8 JSON)
```

- `nonce` = 12 bytes: `0x00 00 00 00` + an 8-byte big-endian counter.
- The counter is per direction; `0` was used in the confirmation round, data messages start at `1`.
- The receiver tracks the counter it expects; a mismatch closes the connection (replay protection).
- Session keys are ephemeral, so nonce reuse is impossible.
- `N` is capped at 1 MiB. A frame above that closes the connection.

## 5. Messages

All messages are single-line UTF-8 JSON, and the `t` field gives the type. An unknown `t` is
ignored silently for forward compatibility. Unknown fields are ignored too.

### `hello`, once from each side at the start of a connection
```json
{"t":"hello","name":"Pixel 9","platform":"android","proto":3,
 "caps":["battery","clipboard","notification","find_phone","media","file","system","debugging"]}
```

### `battery`, Android → macOS
```json
{"t":"battery","level":72,"charging":true,"status":"charging","temp":29.4,"ts":1750000000000}
```
`status` is one of `charging|discharging|full|not_charging|unknown`. `temp` is in °C and optional.

### `clipboard`, bidirectional
```json
{"t":"clipboard","text":"copied text","ts":1750000000000}
```
Only `text/plain` is sent. Empty text is not sent, and anything above 64 KiB is truncated.

Sensitive content is never sent in either direction. Password managers and OTP fields mark the
clipboard as secret, and each platform has its own marker for it:

- Android: `ClipDescription.EXTRA_IS_SENSITIVE` (`android.content.extra.IS_SENSITIVE`), read by
  its string name on every supported version. A clipboard carrying that flag never leaves the
  phone.
- macOS: the de-facto pasteboard types `org.nspasteboard.ConcealedType` and
  `org.nspasteboard.TransientType`, which macOS clipboard managers already honour. A pasteboard
  carrying either type never leaves the Mac.

The rule applies to automatic and manual sends alike, because sending a password on purpose still
puts it on the other device's clipboard. The user can turn this off on either side; it is on by
default on both.

The two directions work differently because of a platform rule. For macOS → Android the user
chooses between automatic and manual. In automatic mode the Mac watches its own pasteboard (§6)
and sends on change. Android → macOS is never automatic, because since Android 10 an app that is
not focused and is not the active keyboard cannot read the clipboard at all. The phone therefore
sends when asked: from its Quick Settings tile, the share sheet, the in-app button, or in answer
to `clipboard_request` below.

### `clipboard_request`, macOS → Android
```json
{"t":"clipboard_request"}
```
"Send me what you have copied." The Mac sends it when the menu bar panel opens (a setting, on by
default) and when the user presses the pull button next to the clipboard line.

The phone cannot answer from its service, so it raises an invisible helper activity that takes
focus, reads the clipboard and replies with `clipboard`. This needs "Display over other apps" on
the phone, the one exemption from the background-activity-start rule that an ordinary app can
hold. Without that permission the phone posts a notification with a single "Send clipboard"
button instead. A phone that has granted neither answers nothing, and this protocol has no path
that reads a phone's clipboard without one of them.

### `system`, Android → macOS
```json
{"t":"system","ringer":"normal","volume":9,"volume_max":15,"can_silence":true,"wireless_debugging":false}
```
Ringer mode and media volume, sent when the link comes up and whenever either changes on the
phone (a broadcast and a settings observer, no polling). `ringer` is one of
`normal|vibrate|silent`.
`can_silence` reports whether the phone has Do Not Disturb access; without it Android refuses a
silent ringer, so the Mac disables that button instead of sending a command that can only fail.
`wireless_debugging` is Android's Wireless debugging switch (`Settings.Global.adb_wifi_enabled`,
readable by any app). Screen mirroring needs it or a USB cable, and a Mac waiting for it continues
once the phone reports it on. The message is sent only when one of these values changes.

### `system_control`, macOS → Android
```json
{"t":"system_control","cmd":"ringer","mode":"silent"}
{"t":"system_control","cmd":"volume","level":9}
{"t":"system_control","cmd":"test_notification"}
{"t":"system_control","cmd":"open_debugging"}
```
`ringer` and `volume` apply the change and answer with a fresh `system`, so the Mac always shows
the phone's own state instead of the last value it asked for. `test_notification` posts a
notification on the phone that travels back through the listener, which tests the whole
mirroring chain end to end. `open_debugging` (phones with `debugging` in `caps`)
opens Developer options at the Wireless debugging switch, or About phone while Developer options
are still locked. It starts the screen directly with "Display over other apps" and posts a
notification that opens it otherwise. Screen mirroring itself does not use this protocol: the Mac
runs scrcpy over adb, and adb has its own pairing and encryption.

### `notification`, Android → macOS
```json
{"t":"notification","id":"0|com.whatsapp|1234|null|10123","app":"WhatsApp",
 "pkg":"com.whatsapp","title":"Alex","text":"Are you coming?","ts":1750000000000,
 "silent":false,"redacted":false,
 "actions":[{"title":"Reply","reply":true},{"title":"Mark read","reply":false}]}
```
`id` = `StatusBarNotification.key`. macOS stores it to correlate later messages.
`actions[i].reply` says whether that action carries a `RemoteInput`, that is, whether text can be
typed. With `silent=true` macOS shows no banner and plays no sound, and the notification only
lands in the history and in Notification Center. `redacted=true` means the app is on the "title
only" tier. In that case `title`, `text` and `actions` are sent empty, so the content never leaves
the phone.

Apps on the full tier can also send a picture:
```json
{"t":"notification", ..., "img":"<base64 JPEG or PNG>","img_kind":"picture"}
```
- The source is the first match of: the BigPictureStyle picture (`EXTRA_PICTURE`,
  `EXTRA_PICTURE_ICON`), then the image of the last MessagingStyle message (`EXTRA_MESSAGES`, a
  `uri` with an `image/*` `type`, read only when the app lets the listener open it), then the large
  icon (`getLargeIcon`, usually the contact photo). The first two are `img_kind:"picture"`, scaled
  to at most 512 px on the long edge; the large icon is `"avatar"`, at most 128 px.
- JPEG at quality 70, retried once at 40 when over the cap; PNG only for a transparent image of at
  most 32 KiB. At most 96 KiB encoded; a picture still over that after the retry is not sent.
- It is sent only when it changed for that `id`. The phone keeps a digest of the scaled pixels per
  key. An identical re-post, a text-only update and the reconnect push carry no `img`, and the Mac
  keeps the picture it already has for that `id`. A picture that arrives without a text change
  (a contact photo loaded late) is sent `silent`.
- It is never sent with `redacted:true` or for the off tier. The Mac drops one that comes with
  `redacted:true` anyway.
- macOS attaches it to the Notification Center entry (the thumbnail) in place of the app icon, and
  keeps it next to the history entry, sealed with the history key and deleted with that entry.

### `notification_remove`, Android → macOS (the notification was dismissed on the phone)
```json
{"t":"notification_remove","id":"0|com.whatsapp|1234|null|10123"}
```

### `notification_dismiss`, macOS → Android (dismissed on the Mac, dismiss it on the phone too)
```json
{"t":"notification_dismiss","id":"0|com.whatsapp|1234|null|10123"}
```

### `notification_action`, macOS → Android
```json
{"t":"notification_action","id":"0|com.whatsapp|1234|null|10123","action":0,"reply":"Yes"}
```
`action` is the index into the `actions` array. `reply` is present only if that action carries a
`RemoteInput`.

### `app_modes`, Android → macOS
```json
{"t":"app_modes","apps":[{"pkg":"com.whatsapp","label":"WhatsApp","mode":2}]}
```
Sent on connect and on every tier change. `mode`: `0` off, `1` title only, `2` full.
The phone owns this list, and macOS only displays it.

### `app_mode`, macOS → Android
```json
{"t":"app_mode","pkg":"com.whatsapp","mode":0}
```
Sent when the user changes a tier from the Mac (the "Mute" action on a notification, or the Apps
tab). The phone applies it and sends the updated `app_modes` list back.

### `icon_request`, macOS → Android
```json
{"t":"icon_request","pkg":"com.whatsapp"}
```
macOS asks when it sees a package whose icon is not in its on-disk cache. It asks at most once per
session and never again once the icon has been written to disk. If the phone does not
answer, it may be asked again in the next session.

#### Limits on incoming data

The receiver does not rely on the sender's truncation (clipboard 64 KiB) and enforces its own
limits: frame 1 MiB; `app_icon` 512 KiB plus a PNG signature check; `notification` fields `id` ≤
256, `app`/`pkg` ≤ 256, `title`/`text` ≤ 2 KiB; `notification.img` ≤ 96 KiB decoded with `img_kind`
`picture` or `avatar`, a JPEG or PNG signature that ImageIO agrees with, at most 1024 px per side
(checked before decoding), and re-encoded from its pixels so no metadata is kept (a picture that
fails any check is dropped and the notification is still shown); `media` fields ≤ 200; `hello.name`
≤ 64. A field over the limit is truncated; a message with an empty `id` is dropped.
`file_offer.size` ≤ 4 GiB and ≤ free space, `file_offer.name` ≤ 255 bytes after sanitization,
`file_chunk.data` ≤ 512 KiB decoded; a `file_chunk` for an id that was not accepted is dropped.

### `app_icon`, Android → macOS
```json
{"t":"app_icon","pkg":"com.whatsapp","png":"<base64 PNG, 128x128>"}
```
macOS writes it to disk and never asks again. The icon is not embedded in the notification
message: that would mean ~10 KB of extra radio time per notification (§6). macOS verifies the PNG
signature and drops anything above 512 KiB.

### `sleep`, macOS → Android
```json
{"t":"sleep"}
```
Sent to every phone when the Mac is about to sleep. The phone closes the session, goes to the top of
its backoff ladder and runs no mDNS browse until the network changes, the screen comes on or a
session comes up again. A sleeping Mac answers neither a dial nor a browse, so without this message
each phone would spend the night on the ladder. The cost is a reconnect of up to one ladder step
(300 s) after the Mac wakes, or at once when the phone is picked up.

### `ping` / `pong`
```json
{"t":"ping"}
{"t":"pong"}
```
Only macOS sends `ping`, because it is the side on wall power. Android only answers and runs no
timer of its own. The interval is 240 s, and it is per session: with several phones connected the
Mac runs one timer each, so N phones cost N pings from the Mac and still nothing on any phone.

### `find_phone`, macOS → Android
```json
{"t":"find_phone"}
```
The phone plays the alarm sound (`USAGE_ALARM`, maximum volume), vibrates and shows a
high-priority notification. It lasts at most 30 s. The "Found it" action on the notification,
dismissing the notification, opening the app, losing the connection, or a second `find_phone`
(it toggles) stops it at once. The Mac panel shows the button if the phone advertised
`find_phone` in its `caps`.

### `media`, Android → macOS
```json
{"t":"media","active":true,"playing":true,"title":"Song","artist":"Artist","album":"",
 "app":"Spotify","pkg":"com.spotify.music"}
{"t":"media","active":false}
```
The active media session on the phone (`MediaSessionManager`, which comes with the notification
access permission). It is sent only when the track, title, artist or playback state changes,
with a 300 ms coalescing window, and identical content is not sent twice. Position (progress) is
not synced because that would require a timer (§6.10). If media sync is switched off
(`sync_media`), nothing is sent at all.

### `media_control`, macOS → Android
```json
{"t":"media_control","cmd":"play"}
```
`cmd` is one of `play|pause|next|previous`. The phone forwards it to the active session's
`transportControls`, or ignores it when there is no session.

### File transfer, bidirectional (`file_*`)

Files travel over the same authenticated session, with no second socket, key or HTTP server.
The design borrows LocalSend's offer/accept flow and Syncthing's chunk hashing and
temp-file-then-rename. It also avoids two known flaws: Quick Share processed payload frames
before the accept response (CVE-2024-38272), and KDE Connect trusts the transport alone and has
no application-layer hash.

A transfer belongs to the one session it was offered on. With several phones connected the Mac
sends every `file_*` message for a transfer to that phone only and drops `file_*` messages for it
that arrive from any other phone, so no phone can see, feed or cancel another phone's transfer.
The receiver opens a received file by the type its name implies, never by the sender's `mime`.

```json
{"t":"file_offer","id":"<32 hex>","name":"IMG_2031.jpg","size":3182011,"mime":"image/jpeg"}
{"t":"file_accept","id":"<32 hex>"}
{"t":"file_reject","id":"<32 hex>","reason":"declined"}
{"t":"file_chunk","id":"<32 hex>","seq":0,"data":"<base64, at most 512 KiB raw>"}
{"t":"file_ack","id":"<32 hex>","seq":0}
{"t":"file_done","id":"<32 hex>","sha256":"<64 hex, lowercase>"}
{"t":"file_result","id":"<32 hex>","ok":true}
{"t":"file_cancel","id":"<32 hex>","reason":"user"}
```

Flow, sender S → receiver R:

1. S picks `id` (16 random bytes, hex) and sends `file_offer`. `name` is a bare file name
   (no directory part), `size` is the exact byte count, `mime` is optional. Only one transfer
   runs at a time per direction: a second `file_offer` while one is pending or running is answered
   with `file_reject` `reason:"busy"`. Multi-file shares are queued on the sender and offered
   one by one.
2. R validates before it asks the user: `size` ≤ 4 GiB and ≤ the free space on the target
   volume, otherwise it sends `file_reject` with `too_large` or `no_space`. If file transfer
   is switched off in Settings, the reason is `disabled`. Then R asks the user (showing name
   and size), or accepts immediately when the user enabled **Accept files automatically**.
   That toggle only ever applies to pinned peers, because they are the only devices that can
   reach this message. R answers `file_accept` or `file_reject` `declined`. Nothing is written
   to disk before `file_accept`, and a `file_chunk` for an id that was not accepted is ignored
   without allocating anything.
3. S streams `file_chunk` with a window of 8: up to eight chunks may be unacked at once,
   and each `file_ack` frees one slot. Every chunk is exactly `524288` bytes (512 KiB) except
   the last one; `seq` is strictly sequential and R still acks every one of them in order.
   A 512 KiB chunk is ~683 KiB as base64 plus a few bytes of JSON, safely below the 1 MiB
   frame cap of §4, so 8 in flight is 4 MiB. The window is bounded because neither side has a
   back-pressure signal from its socket writer (§6), and an unbounded queue would grow the
   heap by the size of the file. A window of 1 would cost a full round trip per 512 KiB,
   which on a home network caps throughput at a few tens of MB/s however fast the link is,
   with both radios idle in between. R writes each chunk to a temporary location
   (macOS: `.<name>.part` next to the final file; Android: a `MediaStore` Downloads entry with
   `IS_PENDING=1`) and hashes it incrementally.
4. S sends `file_done` with the SHA-256 of the whole file right after the last chunk. It
   travels on the same connection, so it cannot overtake that chunk. The hash is computed while
   streaming so the file is read once; hashing before the offer would read a 1 GB video twice
   on battery. For `size=0` S sends
   `file_done` right after `file_accept`. R verifies only once every chunk has been written.
5. R checks the byte count and the hash, moves the temporary file into place, then answers
   `file_result` `ok:true`. On a mismatch it deletes the temporary file and answers
   `ok:false` with `reason:"hash_mismatch"` (or `write_error`).
6. Either side may send `file_cancel` at any time. The other side stops, deletes any
   temporary file and shows nothing further; the cancel is not acknowledged. If the session
   drops, the transfer is over: temporary files are deleted and nothing is resumed.

Receiver rules (both platforms, enforced regardless of what the sender claims):

- File names are sanitized: keep only the last path component (split on `/` and `\`),
  drop control characters (`< 0x20`, `0x7F`), strip leading dots and whitespace, cap at
  255 bytes of UTF-8 (truncate the stem, keep the extension), fall back to `file` when
  nothing is left. A name that already exists gets ` (n)` before the extension
  (`photo (2).jpg`, never `photo.jpg 2` as AirDrop does).
- `size` is checked against the received byte count; a chunk that would overshoot `size`
  cancels the transfer. Chunks out of order cancel the transfer.
- The received file is never opened, executed or previewed automatically. macOS sets the
  `com.apple.quarantine` attribute on it, like a browser download does, so Gatekeeper
  applies to anything executable. Android saves into `Downloads` through `MediaStore`, so
  the app needs no storage permission and cannot write anywhere else.
- Files land in `~/Downloads` (macOS) and `Downloads/` (Android). The Mac shows one
  notification per received file; clicking it reveals the file in Finder.

Sender rules: the Android share sheet (`ACTION_SEND` / `ACTION_SEND_MULTIPLE`) and dropping
files onto the Mac panel are the only entry points.
Sharing plain text from the Android share sheet sends a `clipboard` message instead of a file.

`hello.caps` from the phone in this version:
`["battery","clipboard","notification","find_phone","media","file","system","debugging"]`. The Mac
sends its own list, which has no `system` or `debugging`: those describe what a phone can be asked
to do. If the other side does not advertise a capability, the matching UI element is hidden.

## 6. Energy contract

These rules are part of the protocol, and both implementations must follow them:

1. Android sets up no periodic wakeup timer at all. Liveness is checked by the Mac's `ping` and by
   TCP's own RST detection.
2. `battery` is sent only when the level changes by at least 1% or the charging state changes,
   and at most once every 60 seconds.
3. `notification` is fully event driven (`NotificationListenerService`), with no polling.
4. While a connection is up, the mDNS browse is off. A network event
   (`ConnectivityManager.NetworkCallback`) triggers reconnection; nothing polls.
5. Reconnect backoff: 1s, 2s, 5s, 15s, 60s, then a 300s ceiling. While the screen is on and the
   phone is on the Mac's network, the ceiling is 60s.
6. The notification filter and content redaction run on the phone. A notification from an app the
   user switched off is dropped there and never sent, because filtering it on macOS would wake
   the radio for nothing. Filter order on the phone: structural (group summary, ongoing,
   foreground service, `LOCAL_ONLY`, non-dismissible, our own notifications, the default-off
   package list), then app tier, then channel importance < DEFAULT (if the silent switch is off),
   then whether there is a connection, then "only while the phone is locked", then empty title
   and text.
   `notification_remove` is sent only for notifications that were sent earlier.
7. App icons are sent once per package for their lifetime (`icon_request` / `app_icon`). A
   notification's picture (`img`) goes only for the full tier, only when it changed for that
   notification, and never above 96 KiB.
8. Notification sending is delayed by 300 ms. Apps can update a notification several times per
   second (download percentage, a "typing" indicator). Repeats inside that window collapse into a
   single send, and anything deleted before the window closes is never sent.
9. Existing notifications sent when the connection comes up are marked `silent=true`, so a
   connect does not flood the Mac with banners. Notifications re-posted with identical content
   are sent `silent` as well.
10. Media state is event driven and position is not synced. `MediaController.Callback` fires
    only when the track or the playback state changes. A progress bar would need a message per
    second, so there is none.
11. Find my phone is a single message, and the phone stops itself after 30 s. The Mac sends no
    "stop" message.
12. File transfer is driven by acks. Chunks go out until eight are unacked, and each `file_ack`
    releases the next one. Nothing polls for progress, and the phone sets no transfer timeout: a
    stalled transfer ends with the session (the Mac's `ping` catches a dead link). Progress UI on
    the phone updates at most once per second, decided by comparing timestamps when an ack arrives,
    never by a ticking timer. The hash is computed while streaming so the file is read once.
13. Ringer and volume are event driven. `system` is sent when the link comes up and then only
    when the phone's own ringer or volume changes (a broadcast and a settings observer). The Mac
    never asks for it, and `clipboard_request` is sent only when the user opens the panel or
    presses the button.
