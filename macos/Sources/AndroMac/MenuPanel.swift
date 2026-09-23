import AndroMacKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar panel: made for a glance. What each phone is doing right now, the controls that
/// belong to a phone in the next room, and the last few notifications. Search, long lists and the
/// settings — including which of battery, clipboard, notifications and media sync at all — live in
/// a separate window ([MainWindow]): what syncs is decided once, not at every glance.
struct MenuPanel: View {

    @EnvironmentObject private var state: AppState
    @ObservedObject private var history = NotificationHistory.shared
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var updates = UpdateCheck.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var transfer = FileTransfer.shared
    /// Non-nil for a moment after the manual clipboard send, to say how it went.
    @State private var clipSend: ClipboardWatcher.ManualSendResult?
    /// True for a moment after ⌘C copied the phone's last clipboard.
    @State private var copiedLast = false

    private let recentCount = 4

    private var isPaired: Bool { Store.shared.isPaired }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            // Only when it says something the device list cannot: the app is not paired yet, or the
            // listener itself is down. Otherwise every phone reports its own state one row below,
            // and repeating it here was the same sentence twice.
            if !isPaired || !state.status.isLive {
                status.padding(.horizontal, Theme.Space.tight)
            }
            if let release = updates.available { update(release).padding(.horizontal, Theme.Space.tight) }
            // Mirroring into a Notification Center that refuses us is the quietest failure the app
            // has, so it is said here, once, with the switch one click away.
            if state.notificationsAuthorized == false {
                notificationsOff.padding(.horizontal, Theme.Space.tight)
            }

            if isPaired {
                DeviceList()

                PanelCard {
                    clipboard
                    if let progress = transfer.progress { files(progress) }
                }

                PanelCard { notifications }
            } else {
                PanelCard { onboarding }
            }

            footer.padding(.horizontal, Theme.Space.tight)
        }
        // `.menuBarExtraStyle(.window)` adds its own inset above and below the content but not at
        // the sides, so the vertical padding is the smaller number to look equal.
        .padding(.horizontal, Theme.panelInset)
        .padding(.top, Theme.panelInset)
        .padding(.bottom, Theme.Space.tight)
        .frame(width: Theme.panelWidth)
        // `.menuBarExtraStyle(.window)` gives the panel a chrome band above and below the content
        // that our view does not reach — verified by filling the content with a flat colour and
        // measuring where it stopped. The band renders the window's own translucency, so against a
        // dark desktop it reads as a lighter, "transparent" strip at the top and bottom edges.
        // Shrinking our padding cannot close it, because the band is outside our view. Painting the
        // background past our own bounds can: the negative inset lets the same material cover the
        // strip, so the panel is one uniform surface from edge to edge.
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .padding(-28)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.18), value: state.headline)
        // Opening the panel is the Mac-side "app opened" moment; the check itself is opt-in and daily.
        .onAppear {
            NotificationMirror.shared.refreshAuthorization()
            updates.checkIfDue()
            // Android cannot push a copy on its own, so opening the panel is when the Mac asks.
            Task { await ClipboardWatcher.shared.requestFromPhones() }
        }
        // Dropping files onto the panel is the second way to send (PROTOCOL §5, sender rules).
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // The phone whose tab is open, the same one the Send file… button talks to.
            guard canSendFiles, let peer = state.focusedDevice?.id else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in FileTransfer.shared.send(urls: [url], to: peer) }
                }
            }
            return true
        }
    }

    // MARK: files

    /// The button exists only while the phone advertises the capability (PROTOCOL §5).
    private var canSendFiles: Bool { state.isConnected && state.peerCaps.contains("file") }

    /// A transfer in flight, under the clipboard row it was started from.
    private func files(_ p: FileTransfer.Progress) -> some View {
        HStack(spacing: Theme.Space.small) {
            Image(systemName: p.outgoing ? "arrow.up.doc" : "arrow.down.doc")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            Text(p.name)
                .font(Theme.Font.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.tight)
            Text("\(p.percent)%")
                .font(Theme.Font.label.monospacedDigit())
                .foregroundStyle(.secondary)
            QuietButton(String(localized: "Cancel")) { transfer.cancel() }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Send")
        guard let peer = state.focusedDevice?.id else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            FileTransfer.shared.send(urls: panel.urls, to: peer)
        }
    }

    // MARK: update

    /// Only while a newer release is known. Clicking installs it — download, checksum, swap and
    /// restart — or opens the release page when this release publishes no macOS build.
    private func update(_ release: Release) -> some View {
        Button {
            if release.macImage == nil {
                NSWorkspace.shared.open(release.url)
            } else {
                Task { await updater.install(release) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: updater.phase.busy ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(updateLine(release))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !updater.phase.busy {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(updater.phase.busy)
        .help(release.macImage == nil ? "Open the release page" : "Install this update and restart")
    }

    private func updateLine(_ release: Release) -> String {
        switch updater.phase {
        case .downloading: return String(localized: "Downloading AndroMac \(release.label)…")
        case .verifying: return String(localized: "Checking the download…")
        case .installing: return String(localized: "Installing and restarting…")
        case .failed(let reason): return reason
        case .idle: return String(localized: "AndroMac \(release.label) is available")
        }
    }

    /// Shown while macOS has notifications turned off for AndroMac. Click opens the pane.
    private var notificationsOff: some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("Notifications are off for AndroMac")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Notification settings")
    }


    // MARK: status

    private var status: some View {
        HStack(spacing: Theme.Space.small) {
            // A still dot. It used to pulse forever while looking for the phone, which put permanent
            // motion in the corner of the screen for a state that is usually not the user's problem
            // to solve — and the headline right next to it already says "Waiting for phone". Colour
            // carries the state; nothing here moves.
            Circle()
                .fill(state.indicatorColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.headline)
                    .font(Theme.Font.title)
                    .lineLimit(1)
                if let sub = state.subheadline {
                    Text(sub)
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: connection guide

    /// While unpaired the panel turns into a setup surface. Toggles and lists are meaningless at
    /// this stage; the user's only job is to connect.
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Text("Connect a phone")
                .font(Theme.Font.heading)

            OnboardingStep(
                number: 1,
                title: String(localized: "Install AndroMac on the phone and open it"),
                detail: nil,
                done: false
            )
            OnboardingStep(
                number: 2,
                title: String(localized: "Put both devices on the same Wi-Fi network"),
                detail: NetworkInfo.localIPv4().map { String(localized: "This Mac: \($0)") }
                    ?? String(localized: "This Mac has no local network"),
                done: NetworkInfo.localIPv4() != nil
            )
            OnboardingStep(
                number: 3,
                title: String(localized: "Tap \"Pair\" on the phone"),
                detail: isListening
                    ? String(localized: "This Mac is visible on the network")
                    : String(localized: "Preparing to broadcast…"),
                done: isListening
            )
        }
    }

    private var isListening: Bool {
        if case .listening = state.status { return true }
        if case .connected = state.status { return true }
        return false
    }

    // MARK: clipboard

    /// The phone's last clipboard, then what can be sent from here: the clipboard either way and
    /// files. Hover shows the whole text, ⌘C puts it back on the Mac clipboard.
    private var clipboard: some View {
        HStack(spacing: Theme.Space.small) {
            Button {
                state.showMainWindow(.clipboard)
            } label: {
                HStack(spacing: Theme.Space.small) {
                    Image(systemName: copiedLast ? "checkmark" : "doc.on.clipboard")
                        .font(Theme.Font.label)
                        .foregroundStyle(copiedLast ? Color.green : Color.secondary)
                        .frame(width: 14)
                    Text(state.lastClipboard.isEmpty
                         ? String(localized: "Text you copy on a phone appears here")
                         : state.lastClipboard.replacingOccurrences(of: "\n", with: " "))
                        .font(Theme.Font.label)
                        .foregroundStyle(state.lastClipboard.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.lastClipboard.isEmpty
                  ? String(localized: "Open clipboard history")
                  : String(state.lastClipboard.prefix(600)))
            .contextMenu {
                Button("Copy", action: copyLast)
                    .keyboardShortcut("c")
                    .disabled(state.lastClipboard.isEmpty)
                Button("Open clipboard history") { state.showMainWindow(.clipboard) }
            }
            .background {
                // ⌘C while the panel is open copies the phone's last clipboard.
                Button("Copy", action: copyLast)
                    .keyboardShortcut("c")
                    .disabled(state.lastClipboard.isEmpty)
                    .opacity(0)
                    .accessibilityHidden(true)
            }

            HStack(spacing: Theme.Space.tight) {
                if canSendClipboard {
                    pullClipboardButton
                    sendClipboardButton
                }
                // The button exists only while the phone advertises the capability (PROTOCOL §5).
                if canSendFiles, transfer.progress == nil {
                    IconButton(symbol: "arrow.up.doc",
                               label: String(localized: "Send files to the phone, or drop them onto this panel"),
                               action: chooseFiles)
                }
            }
            .glassGroup(spacing: Theme.Space.tight)
        }
    }

    /// Back onto the Mac clipboard WITHOUT sending it to the phone again (see `restore`).
    private func copyLast() {
        let text = state.lastClipboard
        guard !text.isEmpty else { return }
        Task {
            await ClipboardWatcher.shared.restore(text)
            copiedLast = true
            try? await Task.sleep(for: .milliseconds(1200))
            copiedLast = false
        }
    }

    /// Ask the phone for what it has copied. The panel does this by itself when it opens; the
    /// button is for the second look, when something was copied while the panel was already open.
    private var pullClipboardButton: some View {
        IconButton(symbol: "arrow.down.circle", label: String(localized: "Ask the phone for its clipboard")) {
            Task { await ClipboardWatcher.shared.requestFromPhones(force: true) }
        }
    }

    /// The Mac's answer to the phone's "Send clipboard" tile. The phone has always had a manual
    /// path because Android forbids background clipboard reads; the Mac only ever had the automatic
    /// one, so with auto-send off there was no way to push a copy across on purpose.
    private var canSendClipboard: Bool {
        state.isConnected && state.peerCaps.contains("clipboard") && Store.shared.syncClipboard
    }

    private var sendClipboardButton: some View {
        IconButton(symbol: clipSendSymbol, label: String(localized: "Send the Mac clipboard"),
                   active: clipSend == .sent) {
            Task {
                let result = await ClipboardWatcher.shared.sendCurrent()
                clipSend = result
                try? await Task.sleep(for: .milliseconds(1400))
                clipSend = nil
            }
        }
    }

    private var clipSendSymbol: String {
        switch clipSend {
        case .sent: return "checkmark"
        case .concealed: return "eye.slash"
        case .empty, .clipboardOff: return "exclamationmark.triangle"
        case nil: return "paperplane"
        }
    }

    // MARK: notifications

    private var recent: [NotificationHistory.Entry] {
        Array(history.entries.prefix(recentCount))
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack {
                Text("Notifications")
                    .font(Theme.Font.heading)
                Spacer()
                if !history.entries.isEmpty {
                    QuietButton(String(localized: "Clear")) { history.clear() }
                }
            }

            if history.entries.isEmpty {
                // The empty state does not just say "nothing", it says when it will fill up, so the
                // user can tell a broken app from one that is simply waiting.
                Text(state.isConnected
                     ? "Notifications from your phones appear here."
                     : "Notifications appear here once a phone connects.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Fixed height: inside `.menuBarExtraStyle(.window)` a list with a flexible height
                // collapses the second time the panel is opened.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recent) { NotificationRow(entry: $0) }
                }
                .frame(height: CGFloat(recent.count) * NotificationRow.height, alignment: .top)

                if history.entries.count > recent.count {
                    QuietButton(String(localized: "Show all (\(history.entries.count))")) {
                        state.showMainWindow(.notifications)
                    }
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: Theme.Space.small) {
            Button {
                state.showSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(Theme.Font.label)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(",", modifiers: .command)
            .help("Open Settings")

            Spacer(minLength: 0)

            Image(systemName: "lock.shield")
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .help("Local network only")
                .accessibilityLabel("Local network only")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(Theme.Font.label)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit AndroMac")
            .accessibilityLabel("Quit AndroMac")
        }
        .frame(height: 24)
    }
}
