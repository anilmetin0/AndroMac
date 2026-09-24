import AndroMacKit
import AppKit
import Foundation

/// The clipboard bridge (Mac side).
///
/// macOS posts no notification when the clipboard changes; polling `NSPasteboard.changeCount` is
/// the only way. It is cheap enough to live with: the poll is a single Mach
/// call, it touches no disk, network or radio, and it runs only while the phone is CONNECTED.
///
/// The poll runs only while it can matter: a phone is connected, automatic sending is on, and the
/// screen is awake and unlocked. Nobody copies on a locked or sleeping Mac, and a MacBook on
/// battery should not be woken 1.4 times a second for nothing. The sleep carries a tolerance so
/// the system can fold these wake-ups into others.
///
/// ponytail: a fixed 0.7 s interval; if it ever shows up in a measurement, a CGEventTap for Cmd+C
/// replaces the poll.
actor ClipboardWatcher {

    static let shared = ClipboardWatcher()

    private var task: Task<Void, Never>?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    /// Echo breaker: the most recent texts we wrote to the clipboard ourselves.
    ///
    /// A single value is not enough. In some environments the clipboard is bridged in both
    /// directions (the Android emulator's clipboard sharing works that way) and the same text comes
    /// back several times in a row; a single-value guard resets on the first match and the
    /// ping-pong begins. So we keep a small window instead.
    private var recentlyWritten: [String] = []
    private let echoWindow = 5

    /// A phone wants the clipboard. Whatever was copied before this is not sent.
    func startWatching() {
        if !wanted { lastChangeCount = NSPasteboard.general.changeCount }
        wanted = true
        observeScreen()
        refresh()
    }

    func stopWatching() {
        wanted = false
        refresh()
    }

    /// Start or stop the poll to match the conditions above. Settings call it when a switch moves.
    func refresh() {
        let run = wanted && !displayAsleep && !locked
            && Store.shared.syncClipboard && Store.shared.clipboardAutoSend
        if run, task == nil {
            // Whatever was copied while the poll was off (auto-send switched off, the screen
            // locked) is not sent when it comes back: the user may have copied a password under
            // "Only when I ask" precisely so it would not go.
            lastChangeCount = NSPasteboard.general.changeCount
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(700), tolerance: .milliseconds(300))
                    await self?.poll()
                }
            }
        } else if !run {
            task?.cancel()
            task = nil
        }
    }

    private var wanted = false
    private var displayAsleep = false
    private var locked = false
    private var observingScreen = false

    private func setScreen(asleep: Bool? = nil, locked: Bool? = nil) {
        if let asleep { displayAsleep = asleep }
        if let locked { self.locked = locked }
        refresh()
    }

    /// Display sleep comes from NSWorkspace, the lock screen only as a distributed notification.
    private func observeScreen() {
        guard !observingScreen else { return }
        observingScreen = true
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, Bool?, Bool?)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, true, nil),
            (workspace, NSWorkspace.screensDidWakeNotification, false, nil),
            (distributed, Notification.Name("com.apple.screenIsLocked"), nil, true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), nil, false),
        ]
        for (center, name, asleep, locked) in events {
            _ = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { await ClipboardWatcher.shared.setScreen(asleep: asleep, locked: locked) }
            }
        }
    }

    /// Clipboard content arriving from the phone — write it locally and arm the echo breaker.
    func applyFromPhone(_ text: String) async {
        writeLocally(text)
        await MainActor.run { ClipboardHistory.shared.record(text, direction: .received) }
    }

    /// Ask the connected phones to send what is on their clipboard.
    ///
    /// Android forbids a background app from reading the clipboard, so the phone can never push a
    /// copy on its own — but it can answer a question. This is that question, and it is what makes
    /// "copy on the phone, paste on the Mac" work without touching the phone: the panel asks when
    /// it opens, the phone reads through its invisible helper activity and replies.
    ///
    /// Only the phone the panel is showing is asked; every other phone would wake its radio and
    /// launch an activity for an answer nobody looks at. Throttled: opening and closing the panel
    /// a few times in a row is one request, not five. The phone itself ignores a request while
    /// its screen is off.
    func requestFromPhones() async {
        guard Store.shared.syncClipboard, Store.shared.clipboardPull else { return }
        if let lastRequest, Date().timeIntervalSince(lastRequest) < 10 { return }
        lastRequest = Date()
        guard let peer = await MainActor.run(body: { AppState.shared.focusedDevice?.id }) else { return }
        await Server.shared.send(["t": "clipboard_request"], to: peer)
    }

    /// The same ceiling as the phone's `Protocol.MAX_CLIPBOARD`.
    static let maxText = 64 * 1024

    private var lastRequest: Date?

    /// Send a text from the history to the phone manually (works even when auto-send is off).
    func sendManually(_ text: String) async {
        let clipped = String(text.prefix(Self.maxText))
        rememberWritten(clipped)          // echo breaker: reading it back must not send it again
        await Server.shared.sendToClipboardTargets([
            "t": "clipboard",
            "text": clipped,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
        ])
        await MainActor.run { ClipboardHistory.shared.record(clipped, direction: .sent) }
    }

    /// Put an item from the history back on the clipboard. It is NOT SENT AGAIN to the phone: the
    /// user restored it to use on the Mac, and the phone already had it.
    func restore(_ text: String) {
        writeLocally(text)
    }

    private func writeLocally(_ text: String) {
        rememberWritten(text)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
    }

    private func rememberWritten(_ text: String) {
        recentlyWritten.removeAll { $0 == text }
        recentlyWritten.append(text)
        if recentlyWritten.count > echoWindow { recentlyWritten.removeFirst() }
    }

    /// Is this clipboard marked "do not record"?
    ///
    /// Password managers and anything else with something to hide flag the pasteboard with the
    /// de-facto types from nspasteboard.org, which every clipboard manager on macOS honours:
    /// `ConcealedType` for secrets, `TransientType` for content that was never meant to be kept.
    /// Syncing either one to a phone would be the worst kind of leak — the Mac's password ends up
    /// in the phone's clipboard, and the phone is the device that gets handed to other people.
    ///
    /// This is the Mac-side twin of the phone's `EXTRA_IS_SENSITIVE` check. It was missing, so
    /// PROTOCOL §5's "sensitive content is never sent" only held in the phone → Mac direction.
    static func isConcealed(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        guard Store.shared.clipboardSkipSensitive else { return false }
        return types.contains(concealed) || types.contains(transient)
    }

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private func poll() async {
        guard Store.shared.syncClipboard, Store.shared.clipboardAutoSend else { return }
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }

        // `changeCount` INCREASES on the `clearContents()` call — the content may not be written
        // yet. If we advanced the counter here we would miss that clipboard forever: on the next
        // poll the counter matches and the text is never sent. So we first check that there is content.
        guard let types = pb.types, !types.isEmpty else { return }
        lastChangeCount = current

        guard !Self.isConcealed(types) else { return }
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        guard !recentlyWritten.contains(text) else { return }

        let clipped = String(text.prefix(Self.maxText))
        await Server.shared.sendToClipboardTargets([
            "t": "clipboard",
            "text": clipped,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
        ])
        await MainActor.run {
            AppState.shared.lastClipboard = clipped
            ClipboardHistory.shared.record(clipped, direction: .sent)
        }
    }
}
