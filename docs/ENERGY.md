# Energy contract

The goal is extra drain on the phone that is too small to measure. The Mac does the work that has
to happen somewhere, but a MacBook runs on battery too, so the Mac also avoids timers it does not
need: nothing polls while the screen is locked or asleep, and every timer carries a tolerance so
macOS can coalesce it.

## Basic principle

Radio wakeups drain the battery far more than data does. A message of 200 bytes costs about the
same as one of 2 KB; the number of times the phone's modem comes out of sleep is what counts.
Every design decision was made against the question "who wakes up, and how often".

## Rules in force

| # | Rule | Where |
|---|---|---|
| 1 | No periodic timer on the phone at all. The Mac does the liveness check (a `ping` every 240 s), and the phone only answers. | `pingTasks` (`Server.swift`) / `LinkService.READ_TIMEOUT_MS` |
| 2 | Battery is sent only on a 1% level change or a charging state change, at most once every 60 s. There is no separate timer; the app uses the `ACTION_BATTERY_CHANGED` broadcast the system already produces. With the screen off a level change is held and sent with the next `pong`, when the Mac's ping has already woken the radio, or when the screen comes on. A charging change goes out at once. | `BatteryReporter.kt` |
| 3 | Notifications are fully event driven. The system already wakes `NotificationListenerService`, so there is no extra cost. | `NotificationRelay.kt` |
| 4 | The mDNS browse is off while connected, because continuous multicast browsing costs measurable battery. Browsing runs only when there is no connection, and for at most 8 s. A paired phone stops 1 s after its own Mac answers, so a neighbour with the same name is seen too. | `Discovery.kt` / `LinkService.PAIRED_SETTLE_MS` |
| 5 | Reconnection is triggered by events: `ConnectivityManager.NetworkCallback` wakes it when the network returns. The backoff is 1, 2, 5, 15, 60, then 300 s. | `LinkService.kt` |
| 6 | The last successful `ip:port` is stored and tried before mDNS, so most reconnections take a single TCP SYN. | `Store.lastEndpoint` |
| 7 | Notification sending is delayed by 300 ms and coalesced. Rapidly updated notifications collapse into one packet (an app that posts the text and then the sender's photo arrives once, whole), and deleted ones are never sent. | `NotificationRelay.schedule` |
| 8 | Silent notifications (channel importance < DEFAULT) are not sent at all by default, since a notification that makes no sound on the phone is not worth waking the radio for. | `NotificationRelay.send` (structural filter in `isRelayable`) |
| 9 | If "only while the phone is locked" is selected, nothing is sent while the phone is in use. | `NotificationRelay.send` |
| 10 | There is no wakelock. The foreground service keeps the connection up and leaves the CPU free to sleep. | `LinkService.kt` |
| 11 | Media state is sent only on change (`MediaController.Callback`), with 300 ms coalescing, and identical content is not sent twice. The progress position is not synced, because that would mean a message per second. | `MediaBridge.kt` |
| 12 | "Find my phone" is a single message. The phone stops itself after 30 s, and the Mac sends no second message. | `FindPhone.kt` |
| 13 | Ringer and volume are reported from a broadcast and a settings observer and never polled: one small `system` message when the link comes up, then one per change the user makes on the phone. | `SystemBridge.kt` |
| 14 | The Mac asks for the phone's clipboard when it needs it. The phone cannot read it in the background anyway, so the Mac sends `clipboard_request` when the panel opens or the user presses the button, and nothing runs on the phone in between. | `ClipboardBridge.macAskedForClipboard` |
| 15 | While disconnected, only the cheap SYN to the cached address runs every cycle. The 8 s mDNS browse runs on the first attempt after a network event or a pairing request, then on every 4th attempt. It runs every cycle only while no address is cached, because nothing else can make progress then. Repeated Wi-Fi flaps inside 10 s do not restart the backoff ladder. | `LinkService.dial` |
| 16 | The update check runs when the app is opened, at most once a day, and never on a timer. An automatic install downloads right after that check, only on an unmetered network and only while the check itself is on; it installs once the user has left the app. On mobile data, or on a phone older than Android 12, it asks instead. | `UpdateCheck.kt` / `UpdateCheck.swift` / `Updater.kt` |
| 17 | Nothing is dialled without Wi-Fi or Ethernet. On mobile data alone the loop parks until the network callback reports a LAN, so a SYN to the Mac's private address never wakes the cellular radio. Sockets are bound to the LAN network, which also reaches the Mac on a Wi-Fi without internet. | `LinkService.lanNetworks` |
| 18 | A network the Mac was never reached on gets the slow ladder. The Mac's network is remembered as prefix and gateway. On any other network the 60 s screen-on ceiling does not apply, and mDNS runs once per network event instead of every 4th attempt. | `LinkService.onMacNetwork` |
| 19 | An identical re-post of a notification is not sent. If the title, text, actions and tier match what the Mac already shows, no message goes out; only the reconnect push resends it, silently. | `NotificationRelay.send` |
| 20 | The ongoing status notification is re-posted only when its text changes, not on every loop cycle. | `LinkService.note` |
| 21 | The Mac says when it goes to sleep (`sleep`, PROTOCOL §5). The phone parks at the top of its ladder with no mDNS until a network or screen event, so it does not redial a sleeping Mac all night. | `Server.installWakeObserver` / `LinkService` |
| 22 | The clipboard request goes to one phone, and only while its screen is on. Opening the panel asks the phone the panel shows, at most every 10 s. A phone with its screen off ignores the request, so it launches no activity and posts no notification from a pocket. | `ClipboardWatcher.requestFromPhones` / `ClipboardBridge.macAskedForClipboard` |
| 23 | Turning the screen on dials only on the Mac's network, and the cached address is only tried there. | `LinkService` screen receiver, `dial` |
| 24 | Only a volume or Wireless debugging setting wakes `SystemBridge`, and a media update that only changes the position schedules nothing. | `SystemBridge.settingsWatcher`, `MediaBridge.callback` |
| 25 | A replayed notification the Mac already shows is dropped on the Mac before the icon copy and the history write, so a reconnect costs the Mac almost nothing. The histories are written at most once a second. | `NotificationMirror.show`, `ClipboardHistory.record` |
| 26 | A notification's picture goes only on the full tier, only when it changed, and never above 96 KiB. There is one picture per notification (the big picture, else the last chat photo, else the large icon), scaled to 512 px (128 px for an avatar) and JPEG encoded on the relay thread inside the 300 ms window. The phone keeps a digest of the scaled pixels per key, so an identical re-post, a text-only update or a reconnect sends no picture again. The title-only and off tiers never send one. | `NotificationRelay.newPicture`, `NotificationImage.kt` |

## Costs deliberately pushed onto the Mac

- The Mac sends the ping. The phone sets up no `AlarmManager` / `WorkManager`.
- The Mac holds every session and pings each one. The phone never learns that other phones
  exist, and its side of the contract is the same whether the Mac has one paired device or
  several.
- The Mac polls the clipboard. macOS posts no notification for a pasteboard change, so polling
  `NSPasteboard.changeCount` is the only way (every 700 ms, with 300 ms of timer tolerance so
  macOS can coalesce it). The poll is a Mach call that touches no disk, network or radio. It runs
  only while at least one phone is connected, automatic sending is on, and the display is awake
  and unlocked, so a MacBook on battery is not woken for a clipboard nobody can change. One
  poller feeds every phone, so a second device costs no extra polling. The ping timer carries
  15 s of tolerance too. As a result, clipboard history only accumulates while a phone is
  connected, which is the price of not polling when idle.
- The Mac has the server role, so the phone holds no listening socket.

### A trap in the test environment

The Android emulator bridges the clipboard with macOS in both directions. Text copied on the Mac
is written into the emulator and from there back into the Mac pasteboard, so `changeCount`
increases on every poll. A real phone has no such bridge. The echo breaker still keeps the last 5
strings, because protection based on a single value resets on the first match and starts a
ping-pong in an environment like this one.

## Measurement

### From inside the app (Mac → Settings → Metrics)

The Metrics tab puts numbers on the rules above. It shows uptime, messages sent and received,
messages per hour, total traffic, reconnect count, and the three most frequent incoming message
types.

The expected idle baseline is about 30 messages per hour per connected phone: the Mac sends a
`ping` every 240 s to each session (15/hour) and each phone returns the same number of `pong`s.
The counter is global, so two connected phones read ~60/hour. Notification and clipboard events add
to that. A much higher rate means a rule has been broken, for example a periodic timer has come
back on the phone or a notification has gone into a loop. The "most frequent" list shows which
feature produces the traffic.

The counters are kept in memory only; no content is stored.

### From the device

```bash
# Unplug the phone, turn the screen off, wait 30 min:
adb shell dumpsys batterystats --reset
# ... 30 min ...
adb shell dumpsys batterystats | grep -A4 "dev.andromac"
```

Look at the `Wake lock` total (should be 0), the `wifi running` time and `Wakeup alarms`
(should be 0). If you see a measurable wakeup, rule 1 or rule 5 has been broken.

## Upgrade path (not needed yet)

- If the phone is on a different network for a long time, dropping the connection and waiting for
  a "Mac is nearby" signal from a BLE advertisement could be cheaper. BLE scanning costs more than
  an idle TCP connection, though, so this only pays off when Wi-Fi is switched off often.
- If clipboard polling starts costing measurable CPU, a `CGEventTap` for Cmd+C could replace
  `NSPasteboard`. For now that would be unnecessary complexity.
