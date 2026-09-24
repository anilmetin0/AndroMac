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

    /// Read once: views ask on every redraw (`AppIcon`).
    static let isOn = ProcessInfo.processInfo.environment["ANDROMAC_DEMO"] == "1"

    @MainActor
    static func seed() {
        guard isOn else { return }
        // A demo instance is driven by hand, so it takes the Dock icon and the keyboard focus that
        // the accessory policy would deny it.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // ANDROMAC_DEMO_APPEARANCE=light or dark, for both screenshots without touching the system's.
        switch ProcessInfo.processInfo.environment["ANDROMAC_DEMO_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

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
        // ANDROMAC_DEMO_OFFLINE=1 leaves the tablet paired but not connected, for the offline card.
        if ProcessInfo.processInfo.environment["ANDROMAC_DEMO_OFFLINE"] == "1" {
            state.devices.removeAll { $0.id == tablet.id }
        }
        state.focusedDeviceID = phone.id
        state.refocus()

        // Oldest first: `add` puts each one on top, so the list ends up newest first, as it would be.
        let now = Date()
        for (index, entry) in notifications.enumerated().reversed() {
            NotificationHistory.shared.add(
                NotificationHistory.Entry(
                    id: "demo-\(index)", app: entry.app, pkg: entry.pkg,
                    title: entry.title, text: entry.text,
                    date: now.addingTimeInterval(Double(index) * -420),
                    image: entry.image
                )
            )
        }

        ClipboardHistory.shared.record("https://github.com/anilmetin0/AndroMac", direction: .sent)
        ClipboardHistory.shared.record("Meeting room B, 14:30", direction: .received)
        ClipboardHistory.shared.record("brew install --cask andromac", direction: .sent)

        // ANDROMAC_DEMO_TAB picks which tab the window opens on, so each screenshot is one launch
        // rather than a click nobody can script reliably.
        // ANDROMAC_DEMO_SETTINGS=permissions picks the settings section the same way.
        let section = SettingsSection(rawValue: ProcessInfo.processInfo.environment["ANDROMAC_DEMO_SETTINGS"] ?? "")
        switch ProcessInfo.processInfo.environment["ANDROMAC_DEMO_TAB"] {
        case "notifications": state.requestedTab = .notifications
        case "settings": state.requestedTab = .setting(section ?? .general)
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
        // ANDROMAC_DEMO_FILE=1 raises the incoming-file prompt; its buttons only close it.
        if ProcessInfo.processInfo.environment["ANDROMAC_DEMO_FILE"] == "1" {
            FileConsentWindow.show(phone: phone.name, name: "Holiday photos.zip", size: 48_200_000) { _ in }
        }
    }

    /// Newest first. The two pictures are drawn in code (`picture`), so no photo is in the repository.
    private static let notifications: [(app: String, pkg: String, title: String, text: String, image: String?)] = [
        ("Messages", "com.google.android.apps.messaging", "Bank", "Your verification code is 481902", nil),
        ("Signal", "org.thoughtcrime.securesms", "Deniz", "Photo", "demo-beach"),
        ("Calendar", "com.google.android.calendar", "Standup", "In 10 minutes · Room B", nil),
        ("Photos", "com.google.android.apps.photos", "Memories", "A day at the coast, one year ago", "demo-sunset"),
        ("Maps", "com.google.android.apps.maps", "Traffic", "12 min to home, light traffic", nil),
        ("Podcasts", "com.google.android.apps.podcasts", "New episode", "Search Engine · 41 min", nil),
    ]

    // MARK: drawn assets

    /// Stand-ins for the phone's app icons: a symbol on a colour, nobody's logo.
    @MainActor
    static func icon(for pkg: String) -> NSImage? {
        guard isOn, let (symbol, color) = iconStyle[pkg] else { return nil }
        if let cached = icons[pkg] { return cached }
        let side: CGFloat = 64
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            rect.fill()
            let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                      width: size.width, height: size.height))
            }
            return true
        }
        icons[pkg] = image
        return image
    }

    @MainActor private static var icons: [String: NSImage] = [:]

    @MainActor private static let iconStyle: [String: (String, NSColor)] = [
        "com.google.android.apps.messaging": ("message.fill", .systemBlue),
        "org.thoughtcrime.securesms": ("bubble.left.and.bubble.right.fill", .systemIndigo),
        "com.google.android.calendar": ("calendar", .systemRed),
        "com.google.android.apps.photos": ("photo.on.rectangle", .systemOrange),
        "com.google.android.apps.maps": ("map.fill", .systemGreen),
        "com.google.android.apps.podcasts": ("mic.fill", .systemPurple),
        "com.spotify.music": ("music.note", .systemGreen),
    ]

    /// A small landscape for a notification picture: sky, sun, sea.
    static func picture(named name: String) -> CGImage? {
        guard isOn else { return nil }
        let side = 240
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let sunset = name == "demo-sunset"
        let sky = sunset
            ? [CGColor(srgbRed: 0.35, green: 0.22, blue: 0.55, alpha: 1), CGColor(srgbRed: 0.98, green: 0.55, blue: 0.30, alpha: 1)]
            : [CGColor(srgbRed: 0.25, green: 0.55, blue: 0.90, alpha: 1), CGColor(srgbRed: 0.70, green: 0.88, blue: 0.98, alpha: 1)]
        let top = CGFloat(side), horizon = CGFloat(side) * 0.38
        if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: horizon), options: [])
        }
        ctx.setFillColor(sunset ? CGColor(srgbRed: 1, green: 0.85, blue: 0.55, alpha: 1)
                                : CGColor(srgbRed: 1, green: 0.97, blue: 0.85, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: sunset ? 90 : 150, y: horizon - (sunset ? 28 : -70), width: 56, height: 56))
        ctx.setFillColor(sunset ? CGColor(srgbRed: 0.20, green: 0.16, blue: 0.35, alpha: 1)
                                : CGColor(srgbRed: 0.05, green: 0.40, blue: 0.60, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(side), height: horizon))
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.84, blue: 0.66, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: -60, y: -150, width: 300, height: 200))
        return ctx.makeImage()
    }

    /// The panel and the window as plain windows, so a screenshot needs no clicking.
    ///
    /// `MenuBarExtra(.window)` cannot be opened from code, and driving the status item through the
    /// accessibility API is a coin flip. The views are the shipping ones; only the container is not.
    @MainActor
    static func openWindows() {
        guard isOn else { return }
        let state = AppState.shared

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 10),
            // Titled rather than borderless: a borderless window cannot become key, and every
            // switch in it would then be drawn in its inactive grey.
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Hugs the content like the real panel. The titled container reserves a titlebar the menu
        // bar panel does not have; it came back as a safe area the size of the titlebar, which the
        // fitting size counted and `ignoresSafeArea` then left empty at the bottom. No safe area at
        // all, and the window follows the view's own size from then on.
        let host = NSHostingController(rootView: MenuPanel().environmentObject(state))
        host.safeAreaRegions = []
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // No corner radius of its own: a titled window's corner on macOS 27 measures the same
        // 16 pt as the real panel's (`Theme.Radius.panel`).
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        held.append(panel)

        // The main window is the real `Window` scene, so the sidebar and toolbar get the system's
        // own chrome. Its `openWindow` is handed over by the menu bar label once that is on screen.
        state.openMainWindow?()
        // The screen that was asked for is the one that gets focus: an inactive window draws its
        // switches and selection in grey, which is not what a screenshot of it should show. A
        // prompt (pairing, incoming file) first, then the tab, otherwise the panel keeps it.
        let wantsTab = ProcessInfo.processInfo.environment["ANDROMAC_DEMO_TAB"] != nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let prompt = NSApp.windows.first { $0.level == .floating && $0.isVisible }
            let main = wantsTab
                ? NSApp.windows.first { $0.identifier?.rawValue.contains(AndroMacApp.mainWindowID) == true }
                : nil
            (prompt ?? main)?.makeKeyAndOrderFront(nil)
        }
    }

    /// NSWindow does not retain itself when nothing else does.
    @MainActor private static var held: [NSWindow] = []

    /// A key that only has to be a stable 33 bytes: the demo never runs a handshake.
    private static func key(_ byte: UInt8) -> Data {
        Data([0x02] + [UInt8](repeating: byte, count: 32))
    }
}
