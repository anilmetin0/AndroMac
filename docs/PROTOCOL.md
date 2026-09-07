# AndroMac Wire Protocol v3

Single source of truth. The Android and macOS sides are both written against this document.

## 1. Discovery

- macOS is the **server**. It advertises an `_andromac._tcp` Bonjour service on a dynamic port
  (0 → the OS assigns one).
- TXT records: `n=<device name>`, `v=3`. No key material: the Mac's static key is only sent
  inside the handshake (§2), so a Bonjour browse does not identify the machine beyond its name.
- Android is the **client**. It browses with `NsdManager`.
- Android stores the last successful `ip:port` and tries that first. It starts an mDNS browse only
  if that fails.
- **The browse stops the moment a connection is established** (continuous mDNS scanning costs
  battery).

Traffic stays on the local network. macOS rejects any peer outside the private address ranges
(§3), and neither app ever opens an internet socket.

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

A opens `ct_B`, validates `s_pub_B` as a curve point and **checks its pin here**: a pinned key
that differs closes the connection before message 3, so the phone's static key is never shown
to a peer it does not trust. Only the holder of `s_B`'s private key can open `ct_A`, which is
what makes that guarantee hold against an active peer as well.

A peer that presents any other `proto` byte is rejected ("unsupported protocol version"); there
is no fallback, both apps ship together. The `hello` message (§5) carries `proto: 3` as well.

Both sides then compute:

```
dh2 = ECDH(s_A, e_B)      # authenticates A

transcript = SHA256( "AndroMac/v3" || e_pub_A || e_pub_B || ct_B || ct_A )
prk        = HKDF-Extract( salt = transcript, ikm = dh1 || dh2 || dh3 )
k_a2b      = HKDF-Expand( prk, "AndroMac a2b", 32 )
k_b2a      = HKDF-Expand( prk, "AndroMac b2a", 32 )
```

Confirmation round — each side encrypts `transcript` plus its own fresh 32-byte nonce with its
own direction key, then decrypts what the other side sent and checks it:

```
n_A = 32 random bytes
3b. A -> B : Frame( AES-GCM(k_a2b, nonce=0, transcript || n_A) )     # same flush as ct_A
4.  B -> A : Frame( AES-GCM(k_b2a, nonce=0, transcript || n_B) )
```

B checks that the first 32 bytes of message 3b equal `transcript`, and only then sends message 4.
A checks that the first 32 bytes of message 4 equal `transcript` **and** that
`SHA256("AndroMac/commit" || n_B) == c_B` (B really did commit to this nonce in message 2).
If anything does not decrypt, has the wrong length, or does not match, the connection is
**closed immediately**. This step catches a failed key agreement, an active MITM, and a
responder that tried to pick `n_B` after seeing `n_A`.

## 3. Trust (Pairing / TOFU)

SAS (Short Authentication String) — the 6 digits the user compares across the two screens. It is
bound to the session transcript (both ephemeral keys and both encrypted static keys, which also
covers B's commitment) and to both fresh nonces, so it is different on every connection attempt:

```
sas     = ( first 4 bytes of SHA256("AndroMac/SAS/v3" || transcript || n_A || n_B) as BE uint32 )
          mod 1_000_000
display = sas zero-padded to 6 digits
```

Both sides derive the code from the same attempt, so the two screens show the same digits; a
retry produces a new code on both screens. What gets pinned is still the peer's **static public
key**, never the code, so pairings made before v3 keep working.

**Why not a hash of the static keys.** A code derived only from the two static keys (as in v1)
can be ground offline: an active MITM on the LAN (a rogue Bonjour advertisement with the same
name) holds one key pair toward the phone and another toward the Mac, sees both real static keys
in cleartext (v1 sent them in message 1 and the TXT record), and keeps generating key pairs until
the code on the phone's link equals the code on the Mac's link. With 6 digits that is a birthday
search of roughly a thousand key generations, done before the user ever looks at the screens;
the user then compares two matching codes and pins the attacker. KDE Connect's 2025 advisory on its
truncated verification codes (CWE-222, the same class of flaw) is the concrete precedent. The
v2+ construction is the Bluetooth Numeric Comparison pattern: B must commit to `n_B` before it
sees `n_A`, and A must reveal `n_A` before it sees `n_B`, so neither side, and no one in the
middle, can choose its input after all the others are known. An attacker gets exactly one
1-in-a-million guess per attempt the user actually sees.

- **First contact:** both sides show the code. The user confirms on both. After confirmation the
  other side's **static public key** and its name are pinned permanently.
- **Later connections:** the incoming static public key must be byte-for-byte identical to a
  pinned one, otherwise the connection is rejected. There is no silent re-pinning anywhere.
- **On the phone**, which pins exactly one Mac, a key that differs from the pinned one is a
  "key changed" warning, never a first contact — tapping "Pair" does not drop the pin. **On the
  Mac**, which pins a set of phones, that state does not exist: an unknown key is an unknown
  device and gets the ordinary first-contact prompt (see the multi-device bullet below).
- On first contact the connection is **closed** after the handshake; both sides show the SAS and
  wait for confirmation. On a phone-side mismatch the phone hangs up before message 3 and shows
  "key changed" without a code; the Mac shows that attempt's code. After
  confirmation the phone reconnects. If the Mac side is confirmed later than the phone side, the
  phone's first attempt is still rejected; the phone retries on its backoff ladder (1→2→5 s…),
  so the user does not have to tap a second time.
- On the macOS side the handshake must finish within **10 s**, at most 4 unverified connections
  are held at once, the pairing prompt is shown at most once per 30 s, a key the user rejected in
  that prompt is muted for 1, 2, 4 … 60 minutes (doubling per rejection, cleared by an approval
  or a restart), and an established session is given up only **after** a new connection's
  handshake has succeeded. Another device on the network cannot drop a paired session just by
  opening a TCP connection. Connections from outside the private address ranges (not RFC 1918 /
  link-local / ULA) are rejected before the handshake.
- **The Mac trusts a set of phones; the phone trusts one Mac.** macOS pins a list of static public
  keys and will hold a session with each of them at the same time, keyed by the device's
  fingerprint (the first 8 hex of SHA-256 over its static public key). Android still pins exactly
  one Mac. Consequences on the macOS side:
  - There is no "the pinned key changed" state any more — it is only definable when there can be
    exactly one pinned key. A key that is not in the set is a device that has not been met, whether
    it is a new phone or one that was wiped and reinstalled, and both need the same fresh SAS
    approval. Approving is what protects the user, not the label on the prompt.
  - A reinstalled phone therefore appears as a NEW device and the old entry stays in the list until
    the user removes it. This is deliberate: KDE Connect's alternative — a hard TLS failure with no
    message — leaves a device listed as paired that silently never connects again, with no recovery
    inside the app.
  - Approving a phone never drops another. Unpairing removes one device and leaves the rest.
  - A **paused** device stays paired but is refused at the handshake, which is the only way to make
    "disconnect" stick: merely closing the socket just starts the phone's reconnect ladder.
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
- Session keys are ephemeral → nonce reuse is impossible.
- `N` is capped at **1 MiB**. A frame above that closes the connection.

## 5. Messages

All are single-line UTF-8 JSON; the `t` field gives the type. An unknown `t` is **ignored
silently** (forward compatibility). Unknown fields are ignored too.

### `hello` — once from each side at the start of a connection
```json
{"t":"hello","name":"Pixel 9","platform":"android","proto":3,
 "caps":["battery","clipboard","notification","find_phone","media","file"]}
```

### `battery` — Android → macOS
```json
{"t":"battery","level":72,"charging":true,"status":"charging","temp":29.4,"ts":1750000000000}
```
`status` ∈ `charging|discharging|full|not_charging|unknown`. `temp` in °C, optional.

### `clipboard` — bidirectional
```json
{"t":"clipboard","text":"copied text","ts":1750000000000}
```
`text/plain` only. Empty text is not sent. Anything above 64 KiB is truncated.

**Sensitive content is never sent, in either direction.** Password managers and OTP fields mark
the clipboard as secret, and each platform has its own marker for it:

- Android: `ClipDescription.EXTRA_IS_SENSITIVE` (API 33+). A clipboard carrying that flag never
  leaves the phone.
- macOS: the de-facto pasteboard types `org.nspasteboard.ConcealedType` and
  `org.nspasteboard.TransientType`, which macOS clipboard managers already honour. A pasteboard
  carrying either type never leaves the Mac.

The rule applies to automatic and manual sends alike — asking to send a password on purpose is
still asking to put it on the other device's clipboard. The user can turn this off on either
side; it is on by default on both.

**Direction is asymmetric, by platform rule, not by choice.** macOS → Android is a user choice between automatic and manual; when automatic:
the Mac watches its own pasteboard (§6) and sends on change. Android → macOS is always
user-triggered, because since Android 10 an app that is not focused and is not the active
keyboard cannot read the clipboard at all. Each side therefore offers a manual send — the phone's
Quick Settings tile, share sheet and in-app button; the Mac's send button in the menu bar panel
and the "Send to phone" item in the clipboard history.

### `notification` — Android → macOS
```json
{"t":"notification","id":"0|com.whatsapp|1234|null|10123","app":"WhatsApp",
 "pkg":"com.whatsapp","title":"Alex","text":"Are you coming?","ts":1750000000000,
 "silent":false,"redacted":false,
 "actions":[{"title":"Reply","reply":true},{"title":"Mark read","reply":false}]}
```
`id` = `StatusBarNotification.key`. macOS stores it to correlate later messages.
`actions[i].reply` = whether that action carries a `RemoteInput` (that is, whether text can be
typed). `silent=true` → macOS produces no banner and no sound, the notification only lands in the
history and in Notification Center. `redacted=true` → the app is on the "title only" tier. In that
case `title`, `text` and `actions` are **sent empty**: the content never leaves the phone, it is
not trimmed on macOS.

### `notification_remove` — Android → macOS (the notification was dismissed on the phone)
```json
{"t":"notification_remove","id":"0|com.whatsapp|1234|null|10123"}
```

### `notification_dismiss` — macOS → Android (dismissed on the Mac, dismiss it on the phone too)
```json
{"t":"notification_dismiss","id":"0|com.whatsapp|1234|null|10123"}
```

### `notification_action` — macOS → Android
```json
{"t":"notification_action","id":"0|com.whatsapp|1234|null|10123","action":0,"reply":"Yes"}
```
`action` = index into the `actions` array. `reply` only if that action carries a `RemoteInput`.

### `app_modes` — Android → macOS
```json
{"t":"app_modes","apps":[{"pkg":"com.whatsapp","label":"WhatsApp","mode":2}]}
```
Sent on connect and on every tier change. `mode`: `0` off, `1` title only, `2` full.
**The phone is the single source of truth**; macOS only displays this list.

### `app_mode` — macOS → Android
```json
{"t":"app_mode","pkg":"com.whatsapp","mode":0}
```
Sent when the user changes a tier from the Mac (the "Mute" action on a notification, or the Apps
tab). The phone applies it and sends the updated `app_modes` list back.

### `icon_request` — macOS → Android
```json
{"t":"icon_request","pkg":"com.whatsapp"}
```
macOS asks when it sees a package whose icon is not in its on-disk cache: **at most once per
session**, and **never again** once the icon has been written to disk. If the phone does not
answer, it may be asked again in the next session.

#### Limits on incoming data

The sender's truncation (clipboard 64 KiB) is **not assumed** by the receiver. The receiver
enforces its own limits: frame 1 MiB; `app_icon` 512 KiB plus a PNG signature check;
`notification` fields `id` ≤ 256, `app`/`pkg` ≤ 256, `title`/`text` ≤ 2 KiB; `media` fields ≤ 200;
`hello.name` ≤ 64. A field over the limit is truncated; a message with an empty `id` is dropped.
`file_offer.size` ≤ 4 GiB and ≤ free space, `file_offer.name` ≤ 255 bytes after sanitization,
`file_chunk.data` ≤ 512 KiB decoded; a `file_chunk` for an id that was not accepted is dropped.

### `app_icon` — Android → macOS
```json
{"t":"app_icon","pkg":"com.whatsapp","png":"<base64 PNG, 128x128>"}
```
macOS writes it to disk and never asks again. The icon is not embedded in the notification
message: that would mean ~10 KB of extra radio time per notification (§6). macOS verifies the PNG
signature and drops anything above 512 KiB.

### `ping` / `pong`
```json
{"t":"ping"}
{"t":"pong"}
```
**Only macOS sends `ping`** (it is the side on wall power). Android only answers; it runs no timer
of its own. The interval is 240 s, and it is per session: with several phones connected the Mac
runs one timer each, so N phones cost N pings from the Mac and still nothing on any phone.

### `find_phone` — macOS → Android
```json
{"t":"find_phone"}
```
The phone plays the alarm sound (`USAGE_ALARM`, maximum volume), vibrates and shows a
high-priority notification. It lasts **at most 30 s**; the "Found it" action on the notification,
dismissing the notification, opening the app, losing the connection, or **a second `find_phone`**
(toggle behavior) stops it at once. The Mac panel shows the button if the phone advertised
`find_phone` in its `caps`.

### `media` — Android → macOS
```json
{"t":"media","active":true,"playing":true,"title":"Song","artist":"Artist","album":"",
 "app":"Spotify","pkg":"com.spotify.music"}
{"t":"media","active":false}
```
The active media session on the phone (`MediaSessionManager`, which comes with the notification
access permission). Sent **only on change**: when the track, title, artist or playback state
changes, with a 300 ms coalescing window; identical content is not sent twice. Position (progress)
is **not synced** — that would require a timer (§6.10). If it is switched off (`sync_media`),
nothing is sent at all.

### `media_control` — macOS → Android
```json
{"t":"media_control","cmd":"play"}
```
`cmd` ∈ `play|pause|next|previous`. The phone forwards it to the active session's
`transportControls`; if there is no session it is ignored.

### File transfer — bidirectional (`file_*`)

Files ride on the same authenticated session: no second socket, no second key, no HTTP
server. The design borrows LocalSend's offer/accept flow, Syncthing's chunk-and-hash
integrity and temp-file-then-rename, and fixes what went wrong elsewhere (Quick Share
processed payload frames before the accept response, CVE-2024-38272; KDE Connect trusts the
transport alone and has no application-layer hash).

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
   (no directory part), `size` is the exact byte count, `mime` is optional. **One transfer at
   a time per direction**: a second `file_offer` while one is pending or running is answered
   with `file_reject` `reason:"busy"`. Multi-file shares are queued on the sender and offered
   one by one.
2. R validates before it asks the user: `size` ≤ 4 GiB and ≤ the free space on the target
   volume, otherwise `file_reject` with `too_large` / `no_space`; file transfer switched off
   in Settings → `disabled`. Then R asks the user (name and size shown), or accepts
   immediately when the user enabled **Accept files automatically** — that toggle applies
   only to pinned peers, because those are the only devices that can reach this message.
   R answers `file_accept` or `file_reject` `declined`. **Nothing is written to disk before
   `file_accept`**, and a `file_chunk` for an id that was not accepted is ignored without
   allocating anything.
3. S sends `file_chunk` `seq=0`, then waits for `file_ack` `seq=0` before sending `seq=1`,
   and so on. Every chunk is exactly `524288` bytes (512 KiB) except the last one; `seq` is
   strictly sequential. Window = 1 is deliberate: the phone has no back-pressure signal from
   its socket writer (§6), so an unbounded queue would grow the heap by the size of the file.
   A 512 KiB chunk is ~683 KiB as base64 plus a few bytes of JSON, safely below the 1 MiB
   frame cap of §4. R writes each chunk to a temporary location (macOS: `.<name>.part` next
   to the final file; Android: a `MediaStore` Downloads entry with `IS_PENDING=1`) and hashes
   it incrementally.
4. After the last `file_ack` S sends `file_done` with the SHA-256 of the whole file, computed
   while streaming (the file is read once; hashing before the offer would read a 1 GB video
   twice on battery). For `size=0` S sends `file_done` right after `file_accept`.
5. R checks the byte count and the hash, moves the temporary file into place, then answers
   `file_result` `ok:true`; on mismatch it deletes the temporary file and answers
   `ok:false` with `reason:"hash_mismatch"` (or `write_error`).
6. Either side may send `file_cancel` at any time; the other side stops, deletes any
   temporary file and shows nothing further. Not acknowledged. If the session drops the
   transfer is over: temporary files are deleted, nothing is resumed.

Receiver rules (both platforms, enforced regardless of what the sender claims):

- **File name sanitization**: keep only the last path component (split on `/` and `\`),
  drop control characters (`< 0x20`, `0x7F`), strip leading dots and whitespace, cap at
  255 bytes of UTF-8 (truncate the stem, keep the extension), fall back to `file` when
  nothing is left. A name that already exists gets ` (n)` **before** the extension
  (`photo (2).jpg`, never `photo.jpg 2` — AirDrop's mistake).
- `size` is checked against the received byte count; a chunk that would overshoot `size`
  cancels the transfer. Chunks out of order cancel the transfer.
- The received file is **never opened, executed or previewed automatically**. macOS sets the
  `com.apple.quarantine` attribute on it, exactly like a browser download, so Gatekeeper
  applies to anything executable. Android saves into `Downloads` through `MediaStore`, so
  the app needs no storage permission and cannot write anywhere else.
- Files land in `~/Downloads` (macOS) and `Downloads/` (Android). The Mac shows one
  notification per received file; clicking it reveals the file in Finder.

Sender rules: the Android share sheet (`ACTION_SEND` / `ACTION_SEND_MULTIPLE`) and the Mac
panel's **Send file…** button (or dropping files onto the panel) are the only entry points.
Sharing plain text from the Android share sheet sends a `clipboard` message instead of a file.

`hello.caps` in this version: `["battery","clipboard","notification","find_phone","media","file"]`.
If the other side does not advertise a capability, the matching UI element is hidden.

## 6. Energy contract

These rules are part of the protocol, not an implementation detail:

1. Android sets up no periodic wakeup timer at all. Liveness is checked by the Mac's `ping` and by
   TCP's own RST detection.
2. `battery` is sent only when the level changes by ≥ 1% **or** the charging state changes, and at
   most once every 60 seconds.
3. `notification` is fully event-driven (`NotificationListenerService`), there is no polling.
4. While a connection is up, the mDNS browse is off. Reconnection is triggered by a network event
   (`ConnectivityManager.NetworkCallback`), not by polling.
5. Reconnect backoff: 1s, 2s, 5s, 15s, 60s, then a 300s ceiling.
6. **The notification filter and content redaction are applied at the source.** A notification from
   an app the user switched off is dropped on the phone and never sent. Filtering it on macOS would
   wake the radio for nothing. Filter order on the phone: structural (group summary, ongoing,
   foreground service, `LOCAL_ONLY`, non-dismissible, our own notifications, the default-off
   package list) → app tier → channel importance < DEFAULT (if the silent switch is off) → is
   there a connection → "only while the phone is locked" → empty title and text.
   `notification_remove` is sent only for notifications that were sent earlier.
7. App icons are sent once per package for their lifetime (`icon_request` / `app_icon`).
8. **Notification sending is delayed by 50 ms.** Apps can update a notification several times per
   second (download percentage, a "typing" indicator). Repeats inside that window collapse into a
   single send, and anything deleted before the window closes is never sent.
9. Existing notifications sent when the connection comes up are marked `silent=true` — otherwise
   every connect would be a pop-up storm on the Mac. Notifications re-posted with identical content
   are sent `silent` as well.
10. **Media state is event-driven and position is not synced.** `MediaController.Callback` fires
    only when the track or the playback state changes. Showing a progress bar would mean a message
    per second; it is deliberately absent.
11. **Find my phone** is a single message and the phone stops itself after 30 s; the Mac sends no
    "stop", and the phone waits for no second message.
12. **File transfer is ack-driven, not timer-driven.** The next chunk goes out when the previous
    `file_ack` arrives; nobody polls for progress, and the phone sets no transfer timeout — a
    stalled transfer ends with the session (the Mac's `ping` catches a dead link). Progress UI on
    the phone updates at most once per second, decided by comparing timestamps when an ack
    arrives, never by a ticking timer. The hash is computed while streaming so the file is read once.
