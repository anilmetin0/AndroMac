import AndroMacKit
import AppKit
import Foundation
import SwiftUI

/// The single state object the menu bar UI reads from.
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    struct PairingRequest: Equatable {
        let peerKey: Data
        let peerName: String
        let sas: String
        /// Nothing is paired yet, so this is setup rather than an addition. Only wording depends on
        /// it — the SAS comparison is the same either way.
        let isFirstDevice: Bool
        /// The phone's LAN IPv4, so with two phones around the user can tell which one is asking.
        let address: String?

        /// The short fingerprint of the key being offered, so the user has something stable to
        /// recognise the device by later in Settings.
        var fingerprint: String { PairedDevice.fingerprint(of: peerKey) }
    }

    struct Battery: Equatable {
        var level: Int
        var charging: Bool
        var status: String
        var temperature: Double?
        var updated: Date
    }

    /// The track playing on the phone. NO progress (position) — PROTOCOL §6.10: that would mean a
    /// message every second, which the energy contract does not allow.
    struct Media: Equatable {
        var playing: Bool
        var title: String
        var artist: String
        var app: String
        var pkg: String
    }

    /// The phone's ringer and volume, and whether the Mac may change them.
    ///
    /// Silencing a phone needs Do Not Disturb access on Android, which is a separate grant from the
    /// notification access AndroMac already asks for. `canSilence` says whether that grant is in
    /// place, so the Mac can disable the control instead of sending a command the phone must refuse.
    struct PhoneSystem: Equatable {
        var ringer: String              // "normal" | "vibrate" | "silent"
        var volume: Int
        var volumeMax: Int
        var canSilence: Bool
        /// Wireless debugging is on, so screen mirroring can reach the phone without a cable.
        var wirelessDebugging: Bool = false
    }

    enum Status: Equatable {
        case stopped
        case listening
        case connected(String)
        case failed(String)

        /// The listener is up, whether or not a phone is on the other end. Distinguishes "no phone
        /// right now" from "we are not even listening", which `refocus` must not confuse.
        var isLive: Bool {
            switch self {
            case .connected, .listening: return true
            case .stopped, .failed: return false
            }
        }
    }

    /// What one connected phone is reporting right now.
    ///
    /// Everything the Mac learns about a phone hangs off its session, so when the Mac holds several
    /// sessions there has to be one of these per phone. `id` is the device fingerprint, which is
    /// also the key `Store` files the pairing under.
    struct DeviceState: Equatable, Identifiable {
        let id: String
        var name: String
        var battery: Battery?
        var media: Media?
        var caps: Set<String> = []
        var lastClipboard: String = ""
        var system: PhoneSystem?
        /// The IPv4 address the session came from. Screen mirroring finds the phone in adb by it.
        var host: String?
    }

    /// The phones with a live session, in the order they connected.
    ///
    /// Paired-but-offline devices are NOT here — they live in `Store.pairedDevices`. That is the
    /// same split KDE Connect makes and for the same reason: trust is on disk and outlives any
    /// connection, reachability is a property of the moment. The panel joins the two lists.
    @Published var devices: [DeviceState] = []

    /// The device the single-peer parts of the UI are talking about: the most recent one to connect.
    @Published var focusedDeviceID: String?

    var focusedDevice: DeviceState? {
        devices.first { $0.id == focusedDeviceID } ?? devices.last
    }

    @Published var status: Status = .stopped
    @Published var battery: Battery?
    @Published var pairing: PairingRequest?
    @Published var lastClipboard: String = ""
    /// Bumped by `Store` whenever the paired-device list changes on disk (renames, pause, clipboard
    /// target, unpair). The device rows read the list straight from `Store`, so this is what tells
    /// SwiftUI that the copy on screen is stale.
    @Published var pairedDevicesChanged = 0
    /// The macOS notification grant. Nil until `NotificationMirror` has asked the system.
    @Published var notificationsAuthorized: Bool? = nil

    /// Copy the focused device's readings into the single-peer fields above.
    ///
    /// Those fields are what the menu bar label, the status line and the clipboard line still read from.
    /// Rather than rewrite every one of them at once, the multi-device state is authoritative and
    /// this mirrors the focused device into them, so both descriptions stay true at the same time.
    ///
    /// Each field is written only when it changed: a `@Published` set notifies even when the value
    /// is equal, and every battery or media message would otherwise redraw the menu bar item.
    func refocus() {
        let device = focusedDevice
        Self.assign(&battery, device?.battery)
        Self.assign(&lastClipboard, device?.lastClipboard ?? "")
        Self.assign(&status, device.map { .connected($0.name) } ?? (status.isLive ? .listening : status))
    }

    private static func assign<T: Equatable>(_ field: inout T, _ value: T) {
        if field != value { field = value }
    }

    /// Update one device's state, creating its entry if this is its first message.
    func update(deviceID: String, name: String, _ change: (inout DeviceState) -> Void) {
        if let index = devices.firstIndex(where: { $0.id == deviceID }) {
            // Changed in a copy: writing an element of a `@Published` array notifies even when it
            // comes out equal, and the menu bar label would redraw for every message.
            var device = devices[index]
            change(&device)
            if device != devices[index] { devices[index] = device }
        } else {
            var fresh = DeviceState(id: deviceID, name: name)
            change(&fresh)
            devices.append(fresh)
        }
        if focusedDeviceID == nil { focusedDeviceID = deviceID }
        refocus()
    }

    func removeDevice(id: String) {
        devices.removeAll { $0.id == id }
        if focusedDeviceID == id { focusedDeviceID = devices.last?.id }
        refocus()
    }

    /// Which tab the window opened from the panel should show.
    @Published var requestedTab: MainWindow.Tab = .notifications
    /// Whether a list shows its settings beside it (`MainWindow.Tab.settings`); the same switch for
    /// every list, as the inspector is in Finder.
    @Published var pageSettingsShown = false
    /// The page's width held while the window grows or shrinks around its settings, so the list
    /// stays put and only the settings column is revealed or covered. Nil the rest of the time.
    @Published var frozenListWidth: CGFloat?
    /// The scene's `openWindow` for the main window, handed over by the menu bar label so the
    /// AppKit side (the status item's right-click menu) can open it too.
    var openMainWindow: (() -> Void)?

    /// Settings, on the section last shown if the window was already there.
    func showSettings() {
        if case .setting = requestedTab { showMainWindow(requestedTab) } else { showMainWindow(.settings) }
    }

    /// Bring the main window up on `tab`. In an LSUIElement (accessory) app this does not work in a
    /// single call; the order matters: Dock policy first, then activation, then the window, then
    /// making it key. When the window closes, AppDelegate returns the policy to .accessory.
    func showMainWindow(_ tab: MainWindow.Tab) {
        requestedTab = tab.page
        if tab.page != tab { pageSettingsShown = true }
        present(AndroMacApp.mainWindowID) { self.openMainWindow?() }
    }

    /// The Messages page on one phone: the page follows the focused phone (`Messages.follow`).
    func showMessages(for deviceID: String) {
        focusedDeviceID = deviceID
        refocus()
        showMessages()
    }

    /// The main window's Messages page, on the phone the panel has open (`Messages.follow`).
    func showMessages() { showMainWindow(.messages) }

    /// Posted by everything that opens a window from the panel; the panel closes on it.
    static let closePanel = Notification.Name("AndroMac.closePanel")

    private func present(_ id: String, open: @escaping @MainActor () -> Void) {
        // Activate while the click that asked for the window is still being handled: since macOS
        // 14 activation is cooperative, and a request made 100 ms later, after the panel closed,
        // was refused, so the window opened behind the app in front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NotificationCenter.default.post(name: Self.closePanel, object: nil)
        // Already open: forward at once, in the same click, and a pulse to show where it is. The
        // waits below are for a window still being made; spent on this one they held the pulse
        // back by most of a second.
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains(id) == true }) {
            window.makeKeyAndOrderFront(nil)
            // A beat after the activation, or the growing half ran in one step.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Self.pulse(window) }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            open()
            try? await Task.sleep(for: .milliseconds(200))
            let window = NSApp.windows.first { $0.identifier?.rawValue.contains(id) == true }
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    /// Grows the window a little and lets it settle back, twice as fast as the system's zoom.
    private static func pulse(_ window: NSWindow) {
        // Not in full screen or over a pulse still running, whose frame is already the grown one.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !window.styleMask.contains(.fullScreen), !pulsing else { return }
        pulsing = true
        let frame = window.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame.insetBy(dx: -8, dy: -8), display: true)
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            } completionHandler: {
                MainActor.assumeIsolated { pulsing = false }
            }
        })
    }

    private static var pulsing = false

    /// ⌘Q: every titled window closes, which hands the Dock icon back (see `AppDelegate`). The
    /// menu bar panel is not titled and stays.
    static func closeAppWindows() {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Whether one of the app's own windows is still on screen, so closing another does not take
    /// the Dock icon away from it. The welcome window counts too: it asked for the Dock icon itself.
    /// Any window the user works in, which are the titled ones: the menu bar panel and the drop
    /// shelf are not.
    static func appWindowVisible(except closing: NSWindow? = nil) -> Bool {
        NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
    }

    /// Puts a window up the way a regular app's comes up: Dock icon, ⌘-Tab, App Exposé and the
    /// menu bar, and the focus. An accessory app gets none of them, so a window opened while it
    /// still was one stayed behind and was missing from the three-finger swipe. Closing the last
    /// window hands them back (AppDelegate).
    static func bringForward(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
    /// Published separately so the menu bar label is redrawn.
    @Published var showBatteryInMenuBar: Bool = Store.shared.showBatteryInMenuBar {
        didSet { Store.shared.showBatteryInMenuBar = showBatteryInMenuBar }
    }

    /// The panel's first line: what is going on.
    var headline: String {
        switch status {
        case .stopped:
            return Store.shared.isPaired
                ? String(localized: "Not connected") : String(localized: "Not paired")
        case .listening:
            return Store.shared.isPaired
                ? String(localized: "Waiting for phone") : String(localized: "Not paired")
        case .connected: return String(localized: "Connected")
        case .failed: return String(localized: "Can't connect")
        }
    }

    /// The second line: which device, or why. Hidden when there is nothing to say.
    var subheadline: String? {
        if Store.shared.keychainDenied {
            return String(localized: "Keychain access denied. Restart the app and allow it.")
        }
        switch status {
        case .connected(let name): return AppState.displayName(name)
        case .failed(let message): return message
        case .listening, .stopped:
            return AppState.displayName(Store.shared.pairedDevices.first?.name ?? "")
        }
    }

    /// Android's `Build.MODEL` arrives raw: "sdk_gphone64_arm64", "SM_G991B", "Pixel_7".
    /// Showing a technical identifier in the panel answers no question and breaks the polished tone
    /// of the UI — so we turn it into a readable name. An empty name → nil (the row is hidden entirely).
    static func displayName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return nil }

        let lower = name.lowercased()
        // Emulator identifiers: sdk_gphone64_arm64, sdk_gphone_x86, emulator64_arm64...
        if lower.contains("sdk_gphone") || lower.hasPrefix("emulator") || lower.contains("android_sdk") {
            return String(localized: "Android Emulator")
        }

        // Model names written with underscores or hyphens: "Pixel_7" → "Pixel 7".
        return name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map(String.init)
            .joined(separator: " ")
    }

    /// The status dot. The silhouette already differentiates in the menu bar icon; this colour is an
    /// extra cue.
    var indicatorColor: Color {
        switch status {
        case .connected: return .green
        case .listening: return Store.shared.isPaired ? .orange : .secondary.opacity(0.5)
        case .failed: return .red
        case .stopped: return .secondary.opacity(0.5)
        }
    }

    /// The menu bar silhouette.
    ///
    /// The phone silhouette is kept in EVERY state; only the part that conveys status changes.
    /// Turning into a battery icon while connected made the app lose its identity — the user could
    /// no longer tell which menu bar icon was this app.
    /// The battery detail lives in the panel and, optionally, in the percentage text.
    var menuBarSymbol: String {
        switch status {
        case .connected: return "iphone.gen3.radiowaves.left.and.right"
        case .listening: return Store.shared.isPaired ? "iphone.gen3" : "iphone.gen3.slash"
        case .stopped, .failed: return "iphone.gen3.slash"
        }
    }
}
