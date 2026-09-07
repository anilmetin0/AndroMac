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
    /// Which device rows the user has opened. Only meaningful with more than one phone; the phone
    /// that connected last starts open, because that is the one being used.
    @State private var expandedDevices: Set<String> = []

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

            if isPaired {
                PanelCard { DeviceList(expanded: $expandedDevices) }

                PanelCard {
                    clipboard
                    if canSendFiles {
                        Divider().opacity(0.35)
                        files
                    }
                }

                PanelCard { notifications }
            } else {
                PanelCard { onboarding }
            }

            footer.padding(.horizontal, Theme.Space.tight)
        }
        // Horizontal and vertical padding are deliberately different numbers that are meant to LOOK
        // like the same number. `.menuBarExtraStyle(.window)` wraps this view in a panel that adds
        // its own inset above and below but not at the sides, so a uniform 16 reads as top-heavy —
        // roughly 21 pt of air at the top against 16 at the sides.
        .padding(.horizontal, Theme.inset)
        .padding(.vertical, Theme.Space.medium)
        .frame(width: 340)
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
            if let focused = state.focusedDeviceID { expandedDevices.insert(focused) }
            updates.checkIfDue()
            // Android cannot push a copy on its own, so opening the panel is when the Mac asks.
            Task { await ClipboardWatcher.shared.requestFromPhones() }
        }
        // Dropping files onto the panel is the second way to send (PROTOCOL §5, sender rules).
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard canSendFiles else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in FileTransfer.shared.send(urls: [url]) }
                }
            }
            return true
        }
    }

    // MARK: files

    /// The button exists only while the phone advertises the capability (PROTOCOL §5).
    private var canSendFiles: Bool { state.isConnected && state.peerCaps.contains("file") }

    @ViewBuilder
    private var files: some View {
        if let p = transfer.progress {
            HStack(spacing: 8) {
                Image(systemName: p.outgoing ? "arrow.up.doc" : "arrow.down.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(p.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(p.percent)%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                QuietButton(String(localized: "Cancel")) { transfer.cancel() }
            }
        } else {
            Button {
                chooseFiles()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Send file…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Send files to the phone — or drop them onto this panel")
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Send")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            FileTransfer.shared.send(urls: panel.urls)
        }
    }

    // MARK: update

    /// Only while a newer release is known. Clicking installs it — download, checksum, swap and
    /// restart — or opens the release page when this release publishes no macOS build.
    private func update(_ release: Release) -> some View {
        Button {
            if release.macZip == nil {
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
        .help(release.macZip == nil ? "Open the release page" : "Install this update and restart")
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

    private var separator: some View { Divider().opacity(0.45) }

    // MARK: status

    private var status: some View {
        HStack(spacing: 9) {
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
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(String(localized: "TO CONNECT"))

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

    private var clipboard: some View {
        HStack(spacing: 8) {
            Button {
                openMainWindow(tab: .clipboard)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(state.lastClipboard.isEmpty
                         ? String(localized: "Text you copy on a phone appears here")
                         : state.lastClipboard.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11))
                        .foregroundStyle(state.lastClipboard.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open clipboard history")

            if canSendClipboard {
                pullClipboardButton
                sendClipboardButton
            }
        }
    }

    /// Ask the phone for what it has copied. The panel does this by itself when it opens; the
    /// button is for the second look, when something was copied while the panel was already open.
    private var pullClipboardButton: some View {
        Button {
            Task { await ClipboardWatcher.shared.requestFromPhones(force: true) }
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Ask the phone for its clipboard")
        .accessibilityLabel("Ask the phone for its clipboard")
    }

    /// The Mac's answer to the phone's "Send clipboard" tile. The phone has always had a manual
    /// path because Android forbids background clipboard reads; the Mac only ever had the automatic
    /// one, so with auto-send off there was no way to push a copy across on purpose.
    private var canSendClipboard: Bool {
        state.isConnected && state.peerCaps.contains("clipboard") && Store.shared.syncClipboard
    }

    private var sendClipboardButton: some View {
        Button {
            Task {
                let result = await ClipboardWatcher.shared.sendCurrent()
                clipSend = result
                try? await Task.sleep(for: .milliseconds(1400))
                clipSend = nil
            }
        } label: {
            Image(systemName: clipSendSymbol)
                .font(.system(size: 12))
                .foregroundStyle(clipSend == .sent ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Send the Mac clipboard")
        .accessibilityLabel("Send the Mac clipboard")
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
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionLabel(String(localized: "RECENT NOTIFICATIONS"))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            } else {
                // Fixed height: inside `.menuBarExtraStyle(.window)` a list with a flexible height
                // collapses the second time the panel is opened.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recent) { NotificationRow(entry: $0) }
                }
                .frame(height: CGFloat(recent.count) * NotificationRow.height, alignment: .top)

                if history.entries.count > recent.count {
                    QuietButton(String(localized: "Show all (\(history.entries.count))")) {
                        openMainWindow(tab: .notifications)
                    }
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            // Only the sentence that helps right now. The privacy line used to sit here on every
            // launch forever; it says something true but it is not news after the first read, and
            // it was costing two lines at the bottom of every glance. It lives in Settings, next to
            // the one setting that can send anything off the machine.
            if isPaired, !state.isConnected {
                // Paired but not connected: almost every connection problem is one of these two things.
                Text("AndroMac must be open on the phone, on the same Wi‑Fi network.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Space.tight) {
                Button {
                    openMainWindow(tab: .settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(Theme.Font.label)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Image(systemName: "lock.shield")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Local network only")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(Theme.Font.label)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Quit AndroMac")
                .accessibilityLabel("Quit AndroMac")
            }
            .padding(.top, Theme.Space.hair)
        }
    }

    /// In an LSUIElement (accessory) app, bringing a window to the front does not work in a single
    /// call; the order matters: Dock policy first, then activation, then the window, then making it
    /// key. When the window closes, AppDelegate returns the policy to .accessory.
    private func openMainWindow(tab: MainWindow.Tab) {
        Task { @MainActor in
            state.requestedTab = tab
            NSApp.setActivationPolicy(.regular)
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: AndroMacApp.mainWindowID)
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.windows
                .first { $0.identifier?.rawValue.contains(AndroMacApp.mainWindowID) == true }?
                .makeKeyAndOrderFront(nil)
        }
    }
}
