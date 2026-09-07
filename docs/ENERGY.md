# Energy contract

The goal: extra drain on the phone side that is **too small to measure**. The Mac is assumed to be
on wall power, so the expensive work is deliberately piled onto the Mac.

## Basic principle

What drains the battery is not the data, it is **radio wakeups**. Whether a message is 200 bytes
or 2 KB is almost irrelevant; what matters is how many times the phone's modem comes out of sleep.
Every design decision was therefore made against the question "who wakes up, and how often".

## Rules in force

| # | Rule | Where |
|---|---|---|
| 1 | **No periodic timer on the phone at all.** The Mac does the liveness check (a `ping` every 240 s), the phone only answers. | `Server.swift` pingTask / `LinkService.READ_TIMEOUT_MS` |
| 2 | Battery only on a **1% level change or a charging-state change**, at most once every 60 s. No separate timer — we ride on the `ACTION_BATTERY_CHANGED` broadcast the system already produces. | `BatteryReporter.kt` |
| 3 | Notifications are **fully event-driven**. The system already wakes `NotificationListenerService`; there is no extra cost. | `NotificationRelay.kt` |
| 4 | **The mDNS browse is off while connected.** Continuous multicast browsing costs measurable battery. Browsing runs only when there is no connection, and for at most 8 s. | `Discovery.kt` |
| 5 | Reconnection is **by event, not by polling**: `ConnectivityManager.NetworkCallback` wakes it when the network returns. Backoff 1→2→5→15→60→300 s. | `LinkService.kt` |
| 6 | The last successful `ip:port` is stored and **tried before mDNS**. Most reconnections come down to a single TCP SYN. | `Store.lastEndpoint` |
| 7 | Notification sending is **delayed by 50 ms and coalesced**; rapidly updated notifications collapse into one packet, deleted ones are never sent. | `NotificationRelay.schedule` |
| 8 | Silent notifications (channel importance < DEFAULT) are **not sent at all** by default. There is no point waking the radio for a notification that makes no sound on the phone. | `NotificationRelay.send` (structural filter in `isRelayable`) |
| 9 | If "only while the phone is locked" is selected, nothing is sent while the phone is in use. | `NotificationRelay.send` |
| 10 | **No wakelock.** The foreground service keeps the connection up; it does not keep the CPU awake. | `LinkService.kt` |
| 11 | Media state is sent **only on change** (`MediaController.Callback`), with 300 ms coalescing, and identical content is not sent twice. **Progress position is not synced** — that would have meant a message per second. | `MediaBridge.kt` |
| 12 | "Find my phone" is a single message; the phone stops itself after 30 s, the Mac sends no second message. | `FindPhone.kt` |
| 13 | Ringer and volume are **reported on a broadcast and a settings observer**, never polled: one small `system` message when the link comes up, then one per change the user makes on the phone. | `SystemBridge.kt` |
| 14 | The clipboard is **asked for, not watched**. The phone cannot read it in the background anyway, so the Mac sends `clipboard_request` when the panel opens or the user presses the button, and nothing runs on the phone in between. | `ClipboardBridge.macAskedForClipboard` |
| 15 | While disconnected, only the **cheap cached-address SYN runs every cycle**. The 8 s mDNS browse runs on the first attempt after a network event or a pairing request, then on every 4th attempt — and every cycle only while no address is cached, where nothing else can make progress. Repeated Wi-Fi flaps inside 10 s no longer restart the backoff ladder. | `LinkService.dial` |
| 16 | The **update check runs when the app is opened**, at most once a day, and never on a timer. Installing an update happens only when the user presses the button. | `UpdateCheck.kt` / `UpdateCheck.swift` |

## Costs deliberately pushed onto the Mac

- **The Mac sends the ping.** The phone sets up no `AlarmManager` / `WorkManager`.
- **The Mac holds every session and pings each one.** The phone never learns that other phones
  exist; its side of the contract is unchanged whether the Mac has one paired device or several.
- **The Mac polls the clipboard.** macOS posts no notification for a pasteboard change;
  polling `NSPasteboard.changeCount` is the only way (700 ms). That is a Mach call, it touches
  no disk, network or radio, and it runs **only while at least one phone is connected** — one
  poller feeds every phone, so a second device costs no extra polling. The consequence:
  clipboard history also only accumulates while connected — a deliberate trade to avoid polling
  when idle.
- **The server role sits on the Mac.** The phone holds no listening socket.

### A trap in the test environment

The Android emulator **bridges the clipboard in both directions** with macOS. Text copied on the
Mac is written into the emulator and from there back into the Mac pasteboard, so `changeCount`
increases on every poll. This is specific to the emulator; there is no such bridge on a real
phone. The echo breaker still keeps the last 5 strings rather than a single value, because
single-value protection resets on the first match and starts a ping-pong in an environment like
this one.

## Measurement

### From inside the app (Mac → Settings → Metrics)

The rules above are a claim; this section turns them into numbers. What is shown: uptime,
messages sent and received, **messages per hour**, total traffic, reconnect count, and the three
most frequent incoming message types.

The expected idle baseline is **~30 messages per hour per connected phone**: the Mac sends a
`ping` every 240 s to each session (15/hour) and each phone returns the same number of `pong`s.
The counter is global, so two connected phones read ~60/hour. Notification and clipboard events add
to that. A markedly higher rate says a rule has been broken — for example a periodic timer has
come back on the phone, or a notification has gone into a loop. The "most frequent" list points
directly at the feature producing the traffic.

The counters are kept in memory only; no content is stored.

### From the device

```bash
# Unplug the phone, turn the screen off, wait 30 min:
adb shell dumpsys batterystats --reset
# ... 30 min ...
adb shell dumpsys batterystats | grep -A4 "dev.andromac"
```

What to look at: the `Wake lock` total (should be 0), `wifi running` time, `Wakeup alarms`
(should be 0). If you see a measurable wakeup, rule 1 or rule 5 has been broken.

## Upgrade path (not needed yet)

- If the phone is on a different network for a long time, dropping the connection and waiting for
  a "Mac is nearby" signal from a BLE advertisement could be cheaper. But since BLE scanning costs
  more than an idle TCP connection, this only pays off in a scenario where Wi-Fi is switched off
  frequently.
- If clipboard polling starts costing measurable CPU, a `CGEventTap` for Cmd+C could replace
  `NSPasteboard`. Unnecessary complexity for now.
