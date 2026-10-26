import AppKit
import ApplicationServices
import AndroMacKit

/// Types a one-time code into whatever field has keyboard focus: the "Fill code" button on a
/// notification. The banner button does not bring AndroMac forward, so the field the user was
/// typing in keeps the focus and receives the keystrokes.
///
/// Posting key events needs the Accessibility permission. Without it macOS is asked to show its
/// prompt and the code goes onto the clipboard instead, so the click is never lost.
@MainActor
enum CodeTyper {
    static func fill(_ code: String) async {
        guard VerificationCode.isTypable(code) else {
            await ClipboardWatcher.shared.restore(code)
            return
        }
        guard AXIsProcessTrusted() else {
            // The value of kAXTrustedCheckOptionPrompt; the global itself is not concurrency-safe.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            await ClipboardWatcher.shared.restore(code)
            return
        }
        // The notification response arrives before Notification Center has dismissed its UI.
        // Posting immediately sends the keystrokes to the banner instead of the user's field.
        // Let dismissal finish, then address the foreground app directly. Never activate an app:
        // if the user switched apps during the wait, leave the code on the clipboard instead.
        let target = NSWorkspace.shared.frontmostApplication
        try? await Task.sleep(for: .milliseconds(350))
        guard let target, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              target.bundleIdentifier != "com.apple.notificationcenterui",
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            NSLog("AndroMac: code fill copied instead; foreground app unavailable or changed")
            await ClipboardWatcher.shared.restore(code)
            return
        }
        // A private event source and empty flags keep held modifiers out of the synthetic keys.
        let source = CGEventSource(stateID: .privateState)
        var events: [CGEvent] = []
        for unit in code.utf16 {
            var character = unit
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else {
                    await ClipboardWatcher.shared.restore(code)
                    return
                }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                events.append(event)
            }
        }
        NSLog("AndroMac: code fill posting to %@", target.bundleIdentifier ?? "unknown")
        for event in events { event.postToPid(target.processIdentifier) }
    }
}
