import AndroMacKit
import AppKit
import Foundation

/// The clipboard bridge (Mac side).
///
/// macOS posts no notification when the clipboard changes; polling `NSPasteboard.changeCount` is
/// the only way. That is acceptable because the Mac is on mains power: the poll is a single Mach
/// call, it touches no disk, network or radio, and it runs only while the phone is CONNECTED.
///
/// Deliberate simplification: a fixed 0.7 s interval. Its ceiling is CPU cost — if polling ever
/// shows up in a measurement, replace `NSPasteboard` polling with a CGEventTap listening for
/// Cmd+C. Not worth it for now.
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

    func startWatching() {
        guard task == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                await self?.poll()
            }
        }
    }

    func stopWatching() {
        task?.cancel()
        task = nil
    }

    /// Clipboard content arriving from the phone — write it locally and arm the echo breaker.
    func applyFromPhone(_ text: String) async {
        writeLocally(text)
        await MainActor.run { ClipboardHistory.shared.record(text, direction: .received) }
    }

    /// Send whatever is on the Mac clipboard right now, because the user asked for it.
    ///
    /// The mirror image of the phone's "Send clipboard to Mac" tile. It ignores `clipboardAutoSend`
    /// — that toggle decides whether copying *by itself* sends, not whether the user may send on
    /// purpose — but it still honours the master switch and the concealed-content rule.
    /// Returns what happened so the panel can say something other than nothing.
    @discardableResult
    func sendCurrent() async -> ManualSendResult {
        guard Store.shared.syncClipboard else { return .clipboardOff }
        let pb = NSPasteboard.general
        guard let types = pb.types, !types.isEmpty else { return .empty }
        guard !Self.isConcealed(types) else { return .concealed }
        guard let text = pb.string(forType: .string), !text.isEmpty else { return .empty }

        // Auto-send must not fire for the same copy a moment later.
        lastChangeCount = pb.changeCount
        await sendManually(text)
        return .sent
    }

    enum ManualSendResult: Sendable, Equatable {
        case sent
        case empty
        case concealed
        case clipboardOff
    }

    /// Send a text from the history to the phone manually (works even when auto-send is off).
    func sendManually(_ text: String) async {
        let clipped = String(text.prefix(64 * 1024))
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

        let clipped = String(text.prefix(64 * 1024))
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
