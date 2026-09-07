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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
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
                 ? "If it matches the code on the phone screen, tap Pair. If it differs, Reject — someone may be in the middle."
                 : "A phone you have not paired before is asking to connect. If you are adding a second phone, compare the code and pair it. If you are not expecting this, reject it — and note that a phone whose app was reinstalled arrives as a new device too.")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // The default button (Return) is always the safe one. On first contact the user went
                // looking for this prompt, so Pair is safe to default. An unexpected request while
                // phones are already paired is the suspicious case, so there Reject takes Return and
                // pairing has to be chosen deliberately.
                if request.isFirstDevice {
                    Button("Reject") { decide(false) }
                        .secondaryAction()
                    Button("Pair") { decide(true) }
                        .prominentAction()
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Pair") { decide(true) }
                        .secondaryAction()
                    Button("Reject") { decide(false) }
                        .prominentAction()
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Theme.Space.section)
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
                RoundedRectangle(cornerRadius: Theme.Radius.large)
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
