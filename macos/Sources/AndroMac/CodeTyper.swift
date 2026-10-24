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
        guard VerificationCode.isTypable(code) else { return }
        guard AXIsProcessTrusted() else {
            // The value of kAXTrustedCheckOptionPrompt; the global itself is not concurrency-safe.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            await ClipboardWatcher.shared.restore(code)
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for unit in code.utf16 {
            var character = unit
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                event?.post(tap: .cghidEventTap)
            }
        }
    }
}
