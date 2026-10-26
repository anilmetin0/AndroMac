import AppKit
import AVFoundation
import CoreBluetooth
import SwiftUI

/// The macOS grants AndroMac uses, read live. One list for the welcome window and Settings.
///
/// Read when the app becomes active again, which is when a change made in System Settings shows up,
/// and right after an Allow click. Nothing polls (docs/ENERGY.md).
@MainActor
final class SystemPermissions: NSObject, ObservableObject, CBCentralManagerDelegate {

    static let shared = SystemPermissions()

    enum Grant: Equatable {
        case allowed
        /// macOS has not asked yet; Allow raises the system prompt.
        case notAsked
        /// Refused or turned off; only System Settings can change it.
        case denied
        case checking
    }

    enum Kind: String, CaseIterable, Identifiable {
        case notifications, localNetwork, bluetooth, microphone
        var id: String { rawValue }
    }

    @Published private(set) var microphone = Grant.checking
    @Published private(set) var bluetooth = Grant.checking

    /// Created only by an Allow click: a central manager is what makes macOS ask for Bluetooth.
    /// It never scans.
    private var central: CBCentralManager?
    private var observer: NSObjectProtocol?

    override private init() {
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { SystemPermissions.shared.refresh() } }
        refresh()
    }

    func refresh() {
        NotificationMirror.shared.refreshAuthorization()
        // A demo shows one fixed mix, so a screenshot does not depend on the machine it ran on.
        if DemoMode.isOn {
            microphone = .notAsked; bluetooth = .allowed
            return
        }
        let microphone: Grant = switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .allowed
            case .notDetermined: .notAsked
            default: .denied
        }
        let bluetooth: Grant = switch CBManager.authorization {
            case .allowedAlways: .allowed
            case .notDetermined: .notAsked
            default: .denied
        }
        set(\.microphone, microphone)
        set(\.bluetooth, bluetooth)
    }

    /// Published fields notify even when the value is equal; every activation would redraw both lists.
    private func set(_ field: ReferenceWritableKeyPath<SystemPermissions, Grant>, _ value: Grant) {
        if self[keyPath: field] != value { self[keyPath: field] = value }
    }

    func grant(_ kind: Kind) -> Grant {
        switch kind {
        case .notifications:
            switch AppState.shared.notificationsAuthorized {
            case true?: return .allowed
            case false?: return .denied
            case nil: return .checking
            }
        case .localNetwork:
            // macOS offers no way to read this grant; a listener that is up is the evidence.
            switch AppState.shared.status {
            case .listening, .connected: return .allowed
            case .failed: return .denied
            case .stopped: return DemoMode.isOn ? .allowed : .checking
            }
        case .bluetooth: return bluetooth
        case .microphone: return microphone
        }
    }

    /// Raise the system prompt when macOS still can, otherwise open the exact pane.
    func request(_ kind: Kind) {
        guard !DemoMode.isOn else { return }
        switch (kind, grant(kind)) {
        case (.microphone, .notAsked):
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                refresh()
            }
        case (.bluetooth, .notAsked):
            central = CBCentralManager(delegate: self, queue: nil)
        default:
            Self.openSettings(kind)
        }
    }

    static func openSettings(_ kind: Kind) {
        let privacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
        let url: String
        switch kind {
        case .notifications:
            url = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id="
                + (Bundle.main.bundleIdentifier ?? "")
        case .localNetwork: url = privacy + "LocalNetwork"
        case .bluetooth: url = privacy + "Bluetooth"
        case .microphone: url = privacy + "Microphone"
        }
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in self.refresh() }
    }
}

/// The permission rows, for a grouped `Form`: what each grant is for, its state, and Allow.
struct PermissionList: View {

    @ObservedObject private var permissions = SystemPermissions.shared
    @ObservedObject private var state = AppState.shared
    /// Settings lists the Keychain as well; the welcome window only when it was refused.
    var showsKeychain = true

    var body: some View {
        ForEach(SystemPermissions.Kind.allCases) { kind in
            PermissionRow(kind: kind, grant: permissions.grant(kind))
        }
        if showsKeychain || Store.shared.keychainDenied {
            LabeledContent {
                if Store.shared.keychainDenied {
                    Button("Retry") {
                        Store.shared.retryKeychain()
                        Task { await Server.shared.stop(); await Server.shared.start() }
                    }
                    .controlSize(.small)
                } else {
                    PermissionStatus(text: String(localized: "Allowed"), tone: .green)
                }
            } label: {
                PermissionLabel(symbol: "key", title: String(localized: "Keychain"),
                                detail: String(localized: "Holds this Mac's identity key"))
            }
        }
    }
}

private struct PermissionRow: View {
    let kind: SystemPermissions.Kind
    let grant: SystemPermissions.Grant

    var body: some View {
        LabeledContent {
            switch grant {
            case .allowed:
                PermissionStatus(text: String(localized: "Allowed"), tone: .green)
            case .checking:
                PermissionStatus(text: String(localized: "Checking…"), tone: .secondary)
            case .notAsked:
                Button("Allow") { SystemPermissions.shared.request(kind) }
                    .controlSize(.small)
            case .denied:
                Button("Open Settings") { SystemPermissions.openSettings(kind) }
                    .controlSize(.small)
            }
        } label: {
            PermissionLabel(symbol: symbol, title: title, detail: detail)
        }
    }

    private var symbol: String {
        switch kind {
        case .notifications: return "bell.badge"
        case .localNetwork: return "network"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .microphone: return "mic"
        }
    }

    private var title: String {
        switch kind {
        case .notifications: return String(localized: "Notifications")
        case .localNetwork: return String(localized: "Local Network")
        case .bluetooth: return String(localized: "Bluetooth")
        case .microphone: return String(localized: "Microphone")
        }
    }

    private var detail: String {
        switch kind {
        case .notifications: return String(localized: "Shows your phone's notifications")
        case .localNetwork: return String(localized: "Finds your phone on Wi-Fi")
        case .bluetooth: return String(localized: "Connects calls")
        case .microphone: return String(localized: "Lets you talk on calls from the Mac")
        }
    }
}

private struct PermissionLabel: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Theme.Space.small) {
            Image(systemName: symbol)
                .font(Theme.Font.heading)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionStatus: View {
    let text: String
    let tone: Color

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            Circle().fill(tone).frame(width: 7, height: 7)
            Text(text).font(Theme.Font.label).foregroundStyle(.secondary)
        }
    }
}
