import AndroMacKit
import AppKit
import SwiftUI

// MARK: - Settings

struct SettingsList: View {

    @EnvironmentObject private var state: AppState
    @ObservedObject private var stats = LinkStats.shared
    @State private var showBatteryInMenuBar = Store.shared.showBatteryInMenuBar
    @State private var launchAtLogin = Store.shared.launchAtLogin
    @State private var launchError: String?
    @State private var lowBatteryAlert = Store.shared.lowBatteryAlert
    @State private var lowBatteryThreshold = Store.shared.lowBatteryThreshold
    @State private var notificationSound = Store.shared.notificationSound
    /// `ANDROMAC_DEMO_SETTINGS=permissions` opens that section, so a screenshot is one launch.
    @State private var section: SettingsSection =
        DemoMode.isOn ? SettingsSection(rawValue: ProcessInfo.processInfo.environment["ANDROMAC_DEMO_SETTINGS"] ?? "") ?? .general : .general
    @State private var fileTransfer = Store.shared.fileTransfer
    @State private var fileAutoAccept = Store.shared.fileAutoAccept
    @State private var syncBattery = Store.shared.syncBattery
    @State private var syncClipboard = Store.shared.syncClipboard
    @State private var syncNotifications = Store.shared.syncNotifications
    @State private var syncMedia = Store.shared.syncMedia
    @State private var clipboardAutoSend = Store.shared.clipboardAutoSend
    @State private var clipboardSkipSensitive = Store.shared.clipboardSkipSensitive
    @State private var clipboardPull = Store.shared.clipboardPull
    @State private var language = SettingsList.selectedLanguage
    private let initialLanguage = SettingsList.selectedLanguage
    @ObservedObject private var updates = UpdateCheck.shared
    @ObservedObject private var updater = Updater.shared
    @State private var updateCheck = Store.shared.updateCheck

    var body: some View {
        // A sidebar instead of one long scroll: eleven sections were past the point where a
        // person could find "Files" without reading everything above it.
        HStack(spacing: 0) {
            List(selection: $section) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 168)
            Divider()
            Form {
                switch section {
                case .general: general
                case .sync: sync
                case .clipboard: clipboard
                case .notifications: notifications
                case .files: files
                case .devices: devices
                case .permissions: permissions
                case .network: network
                case .updates: updatesSection
                case .metrics: metrics
                case .privacy: privacy
                }
            }
            .formStyle(.grouped)
            .id(section)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: section)
        }
    }

    // MARK: sections

    private var general: some View {
        Section("General") {
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in
                    // Prevents a retry on the rollback pass (below we set the toggle back to
                    // the system's real state).
                    guard v != Store.shared.launchAtLogin else { return }
                    if let error = Store.shared.setLaunchAtLogin(v) {
                        launchError = error.localizedDescription
                        launchAtLogin = Store.shared.launchAtLogin
                    } else {
                        launchError = nil
                    }
                }
            if let launchError {
                Text(launchError)
                    .font(Theme.Font.label)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Show battery percentage in the menu bar", isOn: $showBatteryInMenuBar)
                .onChange(of: showBatteryInMenuBar) { _, v in
                    state.showBatteryInMenuBar = v
                }

            Picker("Language", selection: $language) {
                Text("System").tag("")
                // The .lproj folders in the bundle determine the list: adding a new translation
                // only means dropping in the file, no code changes here.
                ForEach(SettingsList.languages, id: \.self) { code in
                    Text(SettingsList.languageName(code)).tag(code)
                }
            }
            .onChange(of: language) { _, code in
                // The language is read only at app launch; the change takes effect after a restart.
                if code.isEmpty {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.set([code], forKey: "AppleLanguages")
                }
            }
            if language != initialLanguage {
                QuietButton(String(localized: "Restart")) { SettingsList.relaunch() }
            }
        }
    }

    // What the phone and the Mac share at all. These four used to sit in the menu bar
    // panel, where they were four switches in the way of a glance; they are decided once
    // and then left alone, which is what a settings screen is for.
    @ViewBuilder
    private var sync: some View {
        Section("What syncs") {
            Toggle("Battery", isOn: $syncBattery)
                .onChange(of: syncBattery) { _, v in Store.shared.syncBattery = v }
            Toggle("Clipboard", isOn: $syncClipboard)
                .onChange(of: syncClipboard) { _, v in Store.shared.syncClipboard = v }
            Toggle("Notifications", isOn: $syncNotifications)
                .onChange(of: syncNotifications) { _, v in Store.shared.syncNotifications = v }
            Toggle("Media", isOn: $syncMedia)
                .onChange(of: syncMedia) { _, v in
                    Store.shared.syncMedia = v
                    // Drop the row immediately when switched off: the phone sends no more
                    // updates, and leaving the last track on screen would be stale information.
                    if !v { state.media = nil }
                }
            Text("Off here, the phone never sends it.")
                .font(Theme.Font.label)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Battery") {
            Toggle("Alert me on low battery", isOn: $lowBatteryAlert)
                .onChange(of: lowBatteryAlert) { _, v in Store.shared.lowBatteryAlert = v }
            Picker("Alert threshold", selection: $lowBatteryThreshold) {
                ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!lowBatteryAlert)
            .onChange(of: lowBatteryThreshold) { _, v in Store.shared.lowBatteryThreshold = v }
        }
    }

    private var clipboard: some View {
        Section("Clipboard") {
            Picker("Send automatically", selection: $clipboardAutoSend) {
                Text("Automatically, when I copy").tag(true)
                Text("Only when I ask").tag(false)
            }
            .disabled(!syncClipboard)
            .onChange(of: clipboardAutoSend) { _, v in Store.shared.clipboardAutoSend = v }

            Toggle("Never send a concealed clipboard", isOn: $clipboardSkipSensitive)
                .disabled(!syncClipboard)
                .onChange(of: clipboardSkipSensitive) { _, v in Store.shared.clipboardSkipSensitive = v }

            Toggle("Ask the phone for its clipboard when the panel opens", isOn: $clipboardPull)
                .disabled(!syncClipboard)
                .onChange(of: clipboardPull) { _, v in Store.shared.clipboardPull = v }

            // Being straight about the asymmetry is better than a symmetric-looking setting that
            // silently does nothing in one direction.
            Text("The phone answers when asked. With \"Display over other apps\" granted on the phone the answer is instant; otherwise it shows a notification with one button.")
                .font(Theme.Font.label)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notifications: some View {
        Section("Notifications") {
            Toggle("Play a sound for mirrored notifications", isOn: $notificationSound)
                .onChange(of: notificationSound) { _, v in Store.shared.notificationSound = v }
            LabeledContent("History",
                           value: String(localized: "\(NotificationHistory.shared.entries.count) entries"))
        }
    }

    private var files: some View {
        Section("Files") {
            Toggle("Receive files", isOn: $fileTransfer)
                .onChange(of: fileTransfer) { _, v in Store.shared.fileTransfer = v }
            Toggle("Accept files automatically", isOn: $fileAutoAccept)
                .disabled(!fileTransfer)
                .onChange(of: fileAutoAccept) { _, v in Store.shared.fileAutoAccept = v }
            Text("Files are saved to Downloads. Auto-accept applies to every paired phone.")
                .font(Theme.Font.label)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var updatesSection: some View {
        Section("Updates") {
            Toggle("Check for updates", isOn: $updateCheck)
                .onChange(of: updateCheck) { _, v in
                    Store.shared.updateCheck = v
                    if v { updates.checkIfDue() }
                }
            LabeledContent("Status", value: updateStatus)
            HStack {
                Button("Check now") { Task { await updates.checkNow() } }
                    .disabled(updates.checking || updater.phase.busy)
                if let release = updates.available {
                    if release.macImage == nil {
                        Button(String(localized: "Open the release page")) {
                            NSWorkspace.shared.open(release.url)
                        }
                    } else {
                        Button(String(localized: "Install \(release.label)")) {
                            Task { await updater.install(release) }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(updater.phase.busy)
                    }
                }
            }
            if let installStatus {
                Text(installStatus)
                    .font(Theme.Font.label)
                    .foregroundStyle(installFailed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Asks api.github.com once a day, sending only the app version. Downloads are checked against the release checksum before anything is replaced.")
                .font(Theme.Font.label)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // The APK has to get onto the phone somehow, and typing a GitHub URL on a phone
            // keyboard is the worst part of setting this up. The code is drawn locally from a
            // constant; it fetches nothing and works with the update check switched off.
            LabeledContent {
                QRCode(Release.latestURL)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get the app on the phone")
                    Text("Scan to open the releases page and download the APK.")
                        .font(Theme.Font.label)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var devices: some View {
        Section("Devices") {
            LabeledContent("This Mac", value: Store.shared.deviceName)
            LabeledContent("Version", value: Self.version)

            // One row per pairing, so several phones are as visible here as in the panel.
            // Trust is per device, so removing it is per device too; "Forget all" is the old
            // single-phone Unpair, kept for the case where you are handing the Mac on.
            ForEach(Store.shared.pairedDevices) { device in
                LabeledContent {
                    Button("Forget", role: .destructive) { unpair(device.id) }
                        .controlSize(.small)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppState.displayName(device.name) ?? String(localized: "Phone"))
                        Text(deviceDetail(device))
                            .font(Theme.Font.label)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if Store.shared.pairedDevices.isEmpty {
                Text("No phone is paired yet. Open AndroMac on the phone and follow the code.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if Store.shared.pairedDevices.count > 1 {
                Button("Forget all devices", role: .destructive) { unpair(nil) }
            }
        }
    }

    /// The three macOS grants the app depends on, each with what it is for and a way to fix it.
    /// Android's own grants are not repeated here: the phone is where they are changed.
    private var permissions: some View {
        Section("Permissions") {
            PermissionRow(
                title: String(localized: "Notifications"),
                detail: String(localized: "Mirrored notifications appear in Notification Center."),
                status: notificationStatus.0, tone: notificationStatus.1
            ) {
                if state.notificationsAuthorized == false {
                    Button("Open System Settings") {
                        Self.open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                    }
                }
            }
            PermissionRow(
                title: String(localized: "Local Network"),
                detail: String(localized: "Needed to find the phone over Bonjour."),
                status: networkStatus.0, tone: networkStatus.1
            ) {
                if !state.status.isLive {
                    Button("Open System Settings") { Self.open(Self.localNetworkSettings) }
                }
            }
            PermissionRow(
                title: String(localized: "Keychain"),
                detail: String(localized: "Holds this Mac's identity key."),
                status: Store.shared.keychainDenied
                    ? String(localized: "Denied") : String(localized: "Allowed"),
                tone: Store.shared.keychainDenied ? .orange : .green
            ) {
                if Store.shared.keychainDenied {
                    Button("Retry") { Task { await Server.shared.stop(); await Server.shared.start() } }
                }
            }
            Text("Android permissions are listed on the phone, in AndroMac → Permissions.")
                .font(Theme.Font.label)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { NotificationMirror.shared.refreshAuthorization() }
    }

    private var network: some View {
        Section("Network") {
            LabeledContent("This Mac's address", value: NetworkInfo.localIPv4() ?? String(localized: "no local network"))
            LabeledContent("Bonjour service", value: "_andromac._tcp")
            Text("Both devices must be on the same subnet.")
                .font(Theme.Font.label)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Local Network settings") { Self.open(Self.localNetworkSettings) }
        }
    }

    private var metrics: some View {
        Section("Metrics") {
            LabeledContent("Uptime", value: stats.formattedUptime())
            LabeledContent("Messages",
                           value: String(localized: "\(stats.sent) sent · \(stats.received) received"))
            LabeledContent("Messages / hour", value: String(format: "%.1f", stats.messagesPerHour))
            LabeledContent("Traffic", value: stats.formattedBytes())
            LabeledContent("Reconnects", value: "\(stats.reconnects)")
            if !stats.topTypes.isEmpty {
                LabeledContent(
                    "Most frequent",
                    value: stats.topTypes.map { "\($0.type) ×\($0.count)" }
                        .joined(separator: ", ")
                )
            }
            Text("Idle baseline is about 30 messages per hour for each connected phone.")
                .font(Theme.Font.label)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset counters") { stats.reset() }
        }
    }

    private var privacy: some View {
        Section("Privacy") {
            // Said once, here, next to the one setting that can send anything off the machine.
            // It used to appear on the panel, in the footer and twice in this section, which is
            // three times more often than anyone needs to read it.
            Label {
                Text("Everything stays on your local network, end-to-end encrypted. The optional update check is the only exception.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
            }
            .font(Theme.Font.label)
            .foregroundStyle(.secondary)

            Text("Stored only on this Mac. Cleared when you forget all devices.")
                .font(Theme.Font.label)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: permissions helpers

    private static let localNetworkSettings =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    private var notificationStatus: (String, Color) {
        switch state.notificationsAuthorized {
        case nil: return (String(localized: "Checking…"), .secondary)
        case true?: return (String(localized: "Allowed"), .green)
        case false?: return (String(localized: "Off"), .orange)
        }
    }

    private var networkStatus: (String, Color) {
        switch state.status {
        case .failed: return (String(localized: "Blocked or no network"), .orange)
        case .listening, .connected: return (String(localized: "Allowed"), .green)
        case .stopped: return (String(localized: "Not started"), .secondary)
        }
    }

    /// Fingerprint and reachability: enough to tell two phones of the same model apart, and to see
    /// which one the Mac is actually talking to right now.
    private func deviceDetail(_ device: PairedDevice) -> String {
        let live = state.devices.contains { $0.id == device.id }
        let reach = live ? String(localized: "Connected") : String(localized: "Offline")
        return "\(reach) · \(device.shortFingerprint)"
    }

    /// Forget one device, or every device when `id` is nil. Restarting the listener drops the
    /// session of a phone that is no longer trusted instead of leaving it connected.
    private func unpair(_ id: String?) {
        if let id {
            Store.shared.unpair(id: id)
        } else {
            Store.shared.unpairAll()
            NotificationHistory.shared.clear()
            ClipboardHistory.shared.clear()
            AppModes.shared.clear()
            IconCache.shared.clear()
        }
        Task { await Server.shared.stop(); await Server.shared.start() }
    }

    /// System language or an explicit choice: reading the global domain returns the system's own
    /// list (such as "tr-TR"), which meant the "System" option never appeared selected.
    private static var selectedLanguage: String {
        let domain = UserDefaults.standard
            .persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        return (domain["AppleLanguages"] as? [String])?.first ?? ""
    }

    private static var languages: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }.sorted()
    }

    /// The language's own endonym ("English", "Deutsch"); the code itself if the system does not know it.
    private static func languageName(_ code: String) -> String {
        (Locale.current.localizedString(forIdentifier: code) ?? code).capitalized
    }

    private static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// What the installer is doing, or why it stopped. Nil while it has nothing to say.
    private var installStatus: String? {
        switch updater.phase {
        case .idle: return nil
        case .downloading: return String(localized: "Downloading…")
        case .verifying: return String(localized: "Checking the download against the release checksum…")
        case .installing: return String(localized: "Installing. AndroMac will restart itself.")
        case .failed(let reason): return reason
        }
    }

    private var installFailed: Bool {
        if case .failed = updater.phase { return true }
        return false
    }

    private var updateStatus: String {
        if updates.checking { return String(localized: "Checking…") }
        if let error = updates.lastError { return String(localized: "Could not reach GitHub · \(error)") }
        guard let checked = updates.lastChecked else { return String(localized: "Never checked") }
        let ago = checked.formatted(.relative(presentation: .named))
        if let release = updates.available {
            return String(localized: "\(release.label) available · checked \(ago)")
        }
        return String(localized: "Up to date · checked \(ago)")
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        let commit = info?["AndroMacCommit"] as? String ?? "local"
        return "\(short) (\(build) · \(commit))"
    }
}

/// The sidebar entries, in display order.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, sync, clipboard, notifications, files, devices, permissions, network, updates,
         metrics, privacy

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .sync: return "Sync"
        case .clipboard: return "Clipboard"
        case .notifications: return "Notifications"
        case .files: return "Files"
        case .devices: return "Devices"
        case .permissions: return "Permissions"
        case .network: return "Network"
        case .updates: return "Updates"
        case .metrics: return "Metrics"
        case .privacy: return "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .sync: return "arrow.triangle.2.circlepath"
        case .clipboard: return "doc.on.clipboard"
        case .notifications: return "bell"
        case .files: return "arrow.up.doc"
        case .devices: return "iphone"
        case .permissions: return "checkmark.shield"
        case .network: return "network"
        case .updates: return "arrow.down.circle"
        case .metrics: return "chart.bar"
        case .privacy: return "lock.shield"
        }
    }
}

/// One system grant: what it is for on the left, a status pill and (when not granted) the way to
/// fix it on the right.
private struct PermissionRow<Action: View>: View {

    let title: String
    let detail: String
    let status: String
    let tone: Color
    @ViewBuilder let action: Action

    var body: some View {
        LabeledContent {
            HStack(spacing: Theme.Space.small) {
                HStack(spacing: Theme.Space.tight) {
                    Circle().fill(tone).frame(width: 7, height: 7)
                    Text(status).font(Theme.Font.label)
                }
                action.controlSize(.small)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
