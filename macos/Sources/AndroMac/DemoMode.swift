import AndroMacKit
import AppKit
import SwiftUI

/// Fills the UI with invented data so the screenshots in the README can be taken without a phone —
/// and without a real phone's notifications ending up in a public repository.
///
/// Off unless `ANDROMAC_DEMO=1` is in the environment, which no normal launch sets: double-clicking
/// the app, launching it at login and installing it from the release all leave this untouched. When
/// it is on the app also skips the listener, so a demo instance never binds a port, never advertises
/// over Bonjour and never asks for the local network permission.
///
/// Run it against a throwaway home directory so it writes nothing into the real one:
///
///     HOME=$(mktemp -d) ANDROMAC_DEMO=1 macos/build/AndroMac.app/Contents/MacOS/AndroMac
enum DemoMode {

    static var isOn: Bool { ProcessInfo.processInfo.environment["ANDROMAC_DEMO"] == "1" }

    @MainActor
    static func seed() {
        guard isOn else { return }
        // A demo instance is driven by hand, so it takes the Dock icon and the keyboard focus that
        // the accessory policy would deny it.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        Store.shared.updateCheck = false

        let phone = PairedDevice(key: key(0x11), name: "Pixel 9")
        let tablet = PairedDevice(key: key(0x22), name: "Galaxy Tab S9")
        Store.shared.pairedDevices = [phone, tablet]

        let state = AppState.shared
        state.status = .connected(phone.name)
        state.devices = [
            AppState.DeviceState(
                id: phone.id,
                name: phone.name,
                battery: AppState.Battery(level: 78, charging: true, status: "charging",
                                          temperature: 29.4, updated: Date()),
                media: AppState.Media(playing: true, title: "Sunlight", artist: "Hozier",
                                      album: "Unreal Unearth", app: "Spotify",
                                      pkg: "com.spotify.music"),
                caps: ["clipboard", "media", "find_phone", "file", "system"],
                lastClipboard: "https://github.com/anilmetin0/AndroMac",
                system: AppState.PhoneSystem(ringer: "vibrate", volume: 9, volumeMax: 15,
                                             canSilence: true)
            ),
            AppState.DeviceState(
                id: tablet.id,
                name: tablet.name,
                battery: AppState.Battery(level: 41, charging: false, status: "discharging",
                                          temperature: 27.1, updated: Date()),
                caps: ["clipboard", "file"]
            ),
        ]
        state.focusedDeviceID = phone.id
        state.refocus()

        let now = Date()
        for (index, entry) in notifications.enumerated() {
            NotificationHistory.shared.add(
                NotificationHistory.Entry(
                    id: "demo-\(index)", app: entry.app, pkg: entry.pkg,
                    title: entry.title, text: entry.text,
                    date: now.addingTimeInterval(Double(index) * -420)
                )
            )
        }

        ClipboardHistory.shared.record("https://github.com/anilmetin0/AndroMac", direction: .sent)
        ClipboardHistory.shared.record("Meeting room B, 14:30", direction: .received)
        ClipboardHistory.shared.record("brew install --cask andromac", direction: .sent)

        // ANDROMAC_DEMO_TAB picks which tab the window opens on, so each screenshot is one launch
        // rather than a click nobody can script reliably.
        switch ProcessInfo.processInfo.environment["ANDROMAC_DEMO_TAB"] {
        case "settings": state.requestedTab = .settings
        case "clipboard": state.requestedTab = .clipboard
        case "apps": state.requestedTab = .apps
        default: break
        }

        // ANDROMAC_DEMO_PAIRING=1 also raises the pairing dialog, which is otherwise only reachable
        // by actually pairing a phone.
        if ProcessInfo.processInfo.environment["ANDROMAC_DEMO_PAIRING"] == "1" {
            state.pairing = AppState.PairingRequest(
                peerKey: key(0x33), peerName: "Pixel 9", sas: "428 517", isFirstDevice: true
            )
        }
    }

    private static let notifications: [(app: String, pkg: String, title: String, text: String)] = [
        ("Messages", "com.google.android.apps.messaging", "Bank", "Your verification code is 481902"),
        ("Signal", "org.thoughtcrime.securesms", "Deniz", "Sending the file now"),
        ("Calendar", "com.google.android.calendar", "Standup", "In 10 minutes · Room B"),
        ("Maps", "com.google.android.apps.maps", "Traffic", "12 min to home, light traffic"),
        ("Podcasts", "com.google.android.apps.podcasts", "New episode", "Search Engine · 41 min"),
    ]

    /// The panel and the window as plain windows, so a screenshot needs no clicking.
    ///
    /// `MenuBarExtra(.window)` cannot be opened from code, and driving the status item through the
    /// accessibility API is a coin flip. The views are the shipping ones; only the container is not.
    @MainActor
    static func openWindows() {
        guard isOn else { return }
        let state = AppState.shared

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 10),
            // Titled rather than borderless: a borderless window cannot become key, and every
            // switch in it would then be drawn in its inactive grey.
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: MenuPanel().environmentObject(state))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        held.append(panel)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "AndroMac"
        window.contentView = NSHostingView(rootView: MainWindow().environmentObject(state))
        window.center()
        window.orderFront(nil)
        held.append(window)
    }

    /// NSWindow does not retain itself when nothing else does.
    @MainActor private static var held: [NSWindow] = []

    /// A key that only has to be a stable 33 bytes: the demo never runs a handshake.
    private static func key(_ byte: UInt8) -> Data {
        Data([0x02] + [UInt8](repeating: byte, count: 32))
    }
}
