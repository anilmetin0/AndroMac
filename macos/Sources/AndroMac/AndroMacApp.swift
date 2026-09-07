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
            MenuBarLabel().environmentObject(state)
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

/// The menu bar icon, plus the battery percentage when asked for.
///
/// Also the one view that is always on screen, which makes it the place to hand the scene's
/// `openWindow` to AppKit: the right-click menu on the status item has no SwiftUI environment.
private struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: state.menuBarSymbol)
            if let battery = state.battery, state.showBatteryInMenuBar {
                Text("\(battery.level)")
                    .font(.system(size: 11).monospacedDigit())
            }
        }
        // The icon on its own said nothing under VoiceOver.
        .accessibilityLabel("AndroMac: " + state.headline)
        .onAppear { state.openMainWindow = { openWindow(id: AndroMacApp.mainWindowID) } }
    }
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
        // The status item exists once the scene is up, one runloop turn from now.
        DispatchQueue.main.async { self.installStatusItemMenu() }
    }

    // MARK: right-click on the menu bar icon

    /// `MenuBarExtra(.window)` has no secondary-click menu of its own, so one is attached to the
    /// status bar button it creates. Left click still opens the panel; right click shows this.
    @MainActor
    private func installStatusItemMenu() {
        guard let button = NSApp.windows
            .first(where: { String(describing: type(of: $0)).contains("StatusBarWindow") })?
            .contentView.flatMap(Self.statusBarButton) else { return }
        let click = NSClickGestureRecognizer(target: self, action: #selector(showStatusMenu(_:)))
        click.buttonMask = 0x2
        button.addGestureRecognizer(click)
    }

    private static func statusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let found = statusBarButton(in: sub) { return found } }
        return nil
    }

    @MainActor @objc private func showStatusMenu(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open AndroMac"), action: #selector(openMain), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit AndroMac"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
    }

    @MainActor @objc private func openMain() { openMainWindow(tab: .notifications) }
    @MainActor @objc private func openSettings() { openMainWindow(tab: .settings) }

    /// The same dance as the panel's Settings button: policy, activate, then find the window.
    @MainActor
    private func openMainWindow(tab: MainWindow.Tab) {
        AppState.shared.requestedTab = tab
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.openMainWindow?()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.windows
                .first { $0.identifier?.rawValue.contains(AndroMacApp.mainWindowID) == true }?
                .makeKeyAndOrderFront(nil)
        }
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
