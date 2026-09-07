import AndroMacKit
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
        var album: String
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

        var fraction: Double {
            volumeMax > 0 ? Double(volume) / Double(volumeMax) : 0
        }
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
    @Published var media: Media?
    /// The phone's `hello.caps` list. No button appears in the UI for a capability it did not advertise.
    @Published var peerCaps: Set<String> = []
    /// Bumped by `Store` whenever the paired-device list changes on disk (renames, pause, clipboard
    /// target, unpair). The device rows read the list straight from `Store`, so this is what tells
    /// SwiftUI that the copy on screen is stale.
    @Published var pairedDevicesChanged = 0

    /// Copy the focused device's readings into the single-peer fields above.
    ///
    /// Those fields are what the battery bar, the media row and the clipboard line still read from.
    /// Rather than rewrite every one of them at once, the multi-device state is authoritative and
    /// this mirrors the focused device into them, so both descriptions stay true at the same time.
    func refocus() {
        let device = focusedDevice
        battery = device?.battery
        media = device?.media
        peerCaps = device?.caps ?? []
        lastClipboard = device?.lastClipboard ?? ""
        status = device.map { .connected($0.name) } ?? (status.isLive ? .listening : status)
    }

    /// Update one device's state, creating its entry if this is its first message.
    func update(deviceID: String, name: String, _ change: (inout DeviceState) -> Void) {
        if let index = devices.firstIndex(where: { $0.id == deviceID }) {
            change(&devices[index])
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
    /// Published separately so the menu bar label is redrawn.
    @Published var showBatteryInMenuBar: Bool = Store.shared.showBatteryInMenuBar {
        didSet { Store.shared.showBatteryInMenuBar = showBatteryInMenuBar }
    }

    /// Connected? Lets the UI copy distinguish "waiting" from "connected but quiet" (the empty-state
    /// messages change accordingly).
    var isConnected: Bool {
        if case .connected = status { return true }
        return false
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
            return String(localized: "Keychain access denied — restart the app and allow it")
        }
        switch status {
        case .connected(let name): return AppState.displayName(name)
        case .failed(let message): return message
        case .listening, .stopped:
            return AppState.displayName(Store.shared.pairedName)
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
