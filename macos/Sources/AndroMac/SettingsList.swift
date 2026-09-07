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
        Form {
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
                Toggle("Alert me on low battery (15%)", isOn: $lowBatteryAlert)
                    .onChange(of: lowBatteryAlert) { _, v in Store.shared.lowBatteryAlert = v }
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

            // What the phone and the Mac share at all. These four used to sit in the menu bar
            // panel, where they were four switches in the way of a glance; they are decided once
            // and then left alone, which is what a settings screen is for.
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
                Text("Switched off here, the phone stops sending it at the source — the radio never wakes for it.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                Text("Android forbids a background app from reading the clipboard, so the phone answers a request instead of pushing copies. Allow \"Display over other apps\" there and the answer is instant; otherwise the phone shows a notification with one button.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("What a password manager marks as secret. The phone already refuses to send these.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                        if release.macZip == nil {
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
                Text("Asks api.github.com once a day for the newest release, sending the app version and nothing else. The download is checked against the checksum published with the release before anything is replaced.")
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

            Section("Network") {
                LabeledContent("This Mac's address", value: NetworkInfo.localIPv4() ?? String(localized: "no local network"))
                LabeledContent("Bonjour service", value: "_andromac._tcp")
                Text("Both devices must be on the same subnet.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Local Network settings") {
                    if let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

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

            Section("Privacy") {
                // Said once, here, next to the one setting that can send anything off the machine.
                // It used to appear on the panel, in the footer and twice in this section, which is
                // three times more often than anyone needs to read it.
                Label {
                    Text("Everything stays on your local network, end-to-end encrypted. The optional update check above is the only exception.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)

                LabeledContent("Notification history",
                               value: String(localized: "\(NotificationHistory.shared.entries.count) entries"))
                Text("Stored only on this Mac. Cleared when you forget all devices.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
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
