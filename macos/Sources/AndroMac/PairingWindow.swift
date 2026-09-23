import AppKit
import SwiftUI

/// Pairing confirmation (PROTOCOL §3). Its own window rather than an NSAlert: comparing the code is
/// the most critical moment in the app, and it was unreadable in the narrow box of a system alert.
///
/// The window has NO close button: if it closed without a decision, the caller would think the
/// alert was open forever. The two buttons are the only way out.
@MainActor
enum PairingWindow {

    private static var window: NSWindow?

    static func show(_ request: AppState.PairingRequest,
                     decide: @MainActor @escaping (Bool) -> Void) {
        close()
        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "AndroMac"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: PairingView(request: request) { approved in
                close()
                decide(approved)
            }
        )
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }
}

struct PairingView: View {

    let request: AppState.PairingRequest
    let decide: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.medium) {
            HStack(spacing: Theme.Space.small) {
                if !request.isFirstDevice {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Font.heading)
                        .foregroundStyle(.orange)
                }
                // Both branches are literals: Text takes them as LocalizedStringKey, so they are translated.
                Text(request.isFirstDevice ? "Pairing code" : "Another phone wants to pair")
                    .font(Theme.Font.title)
            }

            if let name = AppState.displayName(request.peerName) {
                Text(name)
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }

            code

            // The fingerprint is the name this device will carry in Settings. Showing it here is
            // what lets the user connect the prompt they approved to the entry they see later.
            Text("Device \(request.fingerprint)")
                .font(Theme.Font.label.monospaced())
                .foregroundStyle(.tertiary)

            Text(request.isFirstDevice
                 ? "Pair only if this code matches the one on the phone."
                 : "Pair only if you are adding a phone and the code matches. A reinstalled app arrives as a new phone.")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.small) {
                Spacer(minLength: 0)
                // Return always rejects. The window comes up on its own, from a network
                // event, and anyone on the Wi-Fi can cause one with a fresh key every time, even
                // before the first phone is paired. A Return typed into another app must never pin
                // a stranger, so pairing is always a deliberate click, even though Pair is the
                // primary, glass-prominent action.
                Button("Reject") { decide(false) }
                    .secondaryAction()
                    .keyboardShortcut(.defaultAction)
                Button("Pair") { decide(true) }
                    .prominentAction()
            }
            .controlSize(.large)
        }
        .padding(Theme.Space.large)
        .frame(width: 380)
    }

    /// The six digits are read as three plus three: this grouping speeds up comparing them by eye
    /// with the code on the phone.
    private var code: some View {
        Text(grouped)
            .font(.system(size: 34, weight: .medium, design: .monospaced))
            .tracking(6)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(Color.secondary.opacity(0.10))
            )
            .textSelection(.enabled)
    }

    private var grouped: String {
        let sas = request.sas
        guard sas.count == 6 else { return sas }
        return "\(sas.prefix(3)) \(sas.suffix(3))"
    }
}
