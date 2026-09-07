import AndroMacKit
import AppKit
import Combine
import SwiftUI

@main
struct AndroMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(state)
        } label: {
            // Icon + battery percentage: readable at a glance in the menu bar.
            HStack(spacing: 3) {
                Image(systemName: state.menuBarSymbol)
                if let battery = state.battery, state.showBatteryInMenuBar {
                    Text("\(battery.level)")
                        .font(.system(size: 11).monospacedDigit())
                }
            }
            // The icon on its own said nothing under VoiceOver.
            .accessibilityLabel("AndroMac: " + state.headline)
        }
        .menuBarExtraStyle(.window)

        // The full history lives in a separate window: the panel stays glanceable, while search and
        // long lists go here.
        Window("AndroMac", id: AndroMacApp.mainWindowID) {
            MainWindow().environmentObject(state)
        }
        .defaultSize(width: 540, height: 580)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {
                Link("AndroMac Help", destination: URL(string: "https://github.com/anilmetin0/AndroMac#readme")!)
            }
        }
    }

    static let mainWindowID = "main"
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var cancellables = Set<AnyCancellable>()
    private var alertOpen = false
    /// A new request arriving while the alert is open must not be dropped: the newest one is kept
    /// and shown once the alert closes.
    private var queuedPairing: AppState.PairingRequest?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)      // do not appear in the Dock
        NotificationMirror.shared.bootstrap()

        AppState.shared.$pairing
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                guard let request else { return }
                MainActor.assumeIsolated { self?.presentPairing(request) }
            }
            .store(in: &cancellables)

        // Hide the Dock icon again when the history window closes — we are a menu bar app.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            // The window is read here; the rest runs on the main actor (queue: .main), which the
            // compiler cannot see through the notification closure.
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, window.identifier?.rawValue.contains(AndroMacApp.mainWindowID) == true
                else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }

        // A demo instance fills the UI from DemoMode and never touches the network (see DemoMode).
        guard !DemoMode.isOn else {
            DemoMode.seed()
            // One runloop turn later: the scenes exist by then, so the demo windows come up on top.
            DispatchQueue.main.async { DemoMode.openWindows() }
            return
        }

        Task { await Server.shared.start() }
        // Every launch offers what it finds — once per release, and never for one that was skipped.
        Task { await UpdateCheck.shared.checkAtLaunch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationHistory.shared.flush()
        ClipboardHistory.shared.flush()
        // stop(updateUI:) does not hop to the MainActor: this thread is waiting on the semaphore,
        // and hopping would deadlock for 2 s on every quit.
        let done = DispatchSemaphore(value: 0)
        Task { await Server.shared.stop(updateUI: false); done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    /// Pairing is confirmed by the user; the code must match the one on the phone (PROTOCOL §3).
    @MainActor
    private func presentPairing(_ request: AppState.PairingRequest) {
        guard !alertOpen else { queuedPairing = request; return }
        alertOpen = true

        PairingWindow.show(request) { [weak self] approved in
            guard let self else { return }
            self.alertOpen = false

            if approved {
                // Added, not replaced: approving a phone must never quietly drop one already paired.
                Store.shared.remember(
                    PairedDevice(key: request.peerKey, name: request.peerName)
                )
            }
            Task { await Server.shared.rearm(key: request.peerKey, approved: approved) }

            let next = self.queuedPairing
            self.queuedPairing = nil
            if let next, next != request { self.presentPairing(next) }
        }
    }
}
