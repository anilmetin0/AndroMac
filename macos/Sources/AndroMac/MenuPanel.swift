import AndroMacKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar panel: made for a glance. What each phone is doing right now, the controls that
/// belong to a phone in the next room, and the last few notifications. Search, long lists and the
/// settings — including which of battery, clipboard, notifications and media sync at all — live in
/// a separate window ([MainWindow]): what syncs is decided once, not at every glance.
struct MenuPanel: View {
    /// Closes the menu bar panel the way a click outside does, so the icon is ready for the next click.
    @Environment(\.dismiss) private var dismiss

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var state: AppState
    @ObservedObject private var history = NotificationHistory.shared

    @ObservedObject private var updates = UpdateCheck.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var transfer = FileTransfer.shared
    @ObservedObject private var calls = BluetoothCalls.shared
    @ObservedObject private var clips = ClipboardHistory.shared
    /// The clipboard row that was just copied, for its check mark.
    @State private var copiedClip: String?
    /// The clipboard row unfolded to its whole text; one at a time.
    /// ANDROMAC_DEMO_PANEL=open starts a demo with the newest copy unfolded and the
    /// notifications grown, for the screenshots of both.
    @State private var openClip: String? = DemoMode.panelOpen ? "last" : nil
    /// Sections grown in place to their whole list, scrolling past `listMax`.
    @State private var allClips = false
    @State private var allNotifications = DemoMode.panelOpen
    /// The notification row unfolded to its whole text; one at a time.
    @State private var openRow: String?

    private let recentCount = 4
    /// The tallest a grown section gets before it scrolls, so the panel stays on screen.
    private static let listMax: CGFloat = 300
    private static let clipPoolSize = 20
    /// How far a row's highlight reaches past the text column (`hoverHighlight`).
    private static let highlightBleed = Theme.Space.tight + 2
    /// The most a grown notifications section lists; the window has the rest.
    private static let notificationsMax = 50
    /// Quick and smooth, close to the system's own disclosure.
    private static let unfold = Animation.smooth(duration: 0.3)

    private var isPaired: Bool { Store.shared.isPaired }

    var body: some View {
        // One surface: sections are set apart by space and a hairline, never by plates, and every
        // row starts at the same inset from the panel's edge.
        VStack(alignment: .leading, spacing: Theme.Space.medium) {
            // Only when it says something the device list cannot: the app is not paired yet, or the
            // listener itself is down. Otherwise every phone reports its own state one row below,
            // and repeating it here was the same sentence twice.
            if !isPaired || !state.status.isLive { status }
            if let release = updates.available { update(release) }
            // Mirroring into a Notification Center that refuses us is the quietest failure the app
            // has, so it is said here, once, with the switch one click away.
            if state.notificationsAuthorized == false { notificationsOff }
            if calls.connected {
                BluetoothCallControls()
                if let error = calls.error { Text(error).font(Theme.Font.label).foregroundStyle(.red) }
                Divider()
            }

            if isPaired {
                DeviceList()
                Divider()
                clipboard
                Divider()
                notifications
            } else {
                onboarding
            }

            Divider()
            footer
        }
        .padding(Theme.panelInset)
        // Pinned to the top: the window takes its new height at once when a section opens, and
        // centred content jumped down before it animated. Pinned, it unfolds downwards.
        .frame(width: Theme.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        // A click that opens a window closes the panel, as a click outside it does; left up, it
        // covered the window it had just opened.
        .onReceive(NotificationCenter.default.publisher(for: AppState.closePanel)) { _ in
            dismiss()
        }
        // `.menuBarExtraStyle(.window)` gives the panel a chrome band above and below the content
        // that our view does not reach — verified by filling the content with a flat colour and
        // measuring where it stopped. The band renders the window's own translucency, so against a
        // dark desktop it reads as a lighter, "transparent" strip at the top and bottom edges.
        // Shrinking our padding cannot close it, because the band is outside our view. Painting the
        // background past our own bounds can: the negative inset lets the same material cover the
        // strip, so the panel is one uniform surface from edge to edge.
        .background {
            panelSurface
                .padding(-28)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.headline)
        // Opening the panel is the Mac-side "app opened" moment; the check itself is opt-in and daily.
        .onAppear {
            // ANDROMAC_DEMO_PANEL=animate unfolds a notification two seconds in, so the
            // motion can be recorded without a click.
            if DemoMode.isOn, ProcessInfo.processInfo.environment["ANDROMAC_DEMO_PANEL"] == "animate" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    // The one with action buttons, the tallest kind of open row.
                    if let entry = history.entries.first(where: { !$0.buttons.isEmpty }) ?? history.entries.first {
                        toggle($openRow, entry.id)
                    }
                }
            }
            NotificationMirror.shared.refreshAuthorization()
            updates.checkIfDue()
            // Android cannot push a copy on its own, so opening the panel is when the Mac asks.
            Task { await ClipboardWatcher.shared.requestFromPhones() }
        }
        // Dropping files onto the panel is the second way to send (PROTOCOL §5, sender rules).
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // The focused phone, and only if it advertises the capability (PROTOCOL §5).
            guard let peer = FileSending.destination else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in FileTransfer.shared.send(urls: [url], to: peer) }
                }
            }
            return true
        }
    }

    /// Liquid Glass on 26+, so the desktop shows through the panel the way it does through
    /// Control Center; the regular material before.
    @ViewBuilder
    private var panelSurface: some View {
        if #available(macOS 26.0, *) {
            Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    // MARK: files

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
            Text(p.waiting ? String(localized: "Waiting for phone") : "\(p.percent)%")
                .font(Theme.Font.label.monospacedDigit())
                .foregroundStyle(.secondary)
            QuietButton(String(localized: "Cancel")) { transfer.cancel() }
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
                // The changelog first; the window's own button installs.
                UpdateWindow.show(release)
            }
        } label: {
            HStack(spacing: Theme.Space.small) {
                Image(systemName: updater.phase.busy ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                Text(updateLine(release))
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !updater.phase.busy {
                    Image(systemName: "chevron.right")
                        .font(Theme.Font.caption.weight(.semibold))
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
        case .downloading(let p): return String(localized: "Downloading AndroMac \(release.label)… \(p)%")
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
            HStack(spacing: Theme.Space.small) {
                Image(systemName: "bell.slash")
                    .font(Theme.Font.label)
                    .foregroundStyle(.orange)
                Text("Notifications are off for AndroMac")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(Theme.Font.caption.weight(.semibold))
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
            PairSteps()
        }
    }

    // MARK: clipboard

    /// The last three copies, the phone's newest first, either direction; the chevron grows the
    /// section in place to the last twenty. A click on a row unfolds its whole text, selectable,
    /// with Copy and Open link under it; the copy button on the row copies at once, and so does ⌘C
    /// for the newest. Sending goes by itself, so no row carries a Send button.
    private var clipboard: some View {
        let rows = allClips ? clipPool : Array(clipPool.prefix(3))
        return VStack(alignment: .leading, spacing: Theme.Space.tight) {
            sectionHeader("Clipboard") { state.showMainWindow(.clipboard) }
            if rows.isEmpty {
                Text("Nothing copied yet")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .frame(height: ClipRow.foldedHeight)
            } else {
                grownList(rows.map { ClipRow.height($0.text, open: openClip == $0.id) }.reduce(0, +),
                          scrolls: allClips) {
                    ForEach(rows, id: \.id) { clip in
                        ClipRow(text: clip.text, direction: clip.direction, open: openClip == clip.id,
                                copied: copiedClip == clip.id,
                                onToggle: { toggle($openClip, clip.id) },
                                onCopy: { copy(clip) },
                                onOpenHistory: { state.showMainWindow(.clipboard) })
                    }
                }
            }
            moreRow(hidden: clipPool.count - rows.count, grown: $allClips)
            if let progress = transfer.progress { files(progress) }
        }
        .background {
            // ⌘C while the panel is open copies the phone's last clipboard; not while a row is
            // open, where ⌘C copies what is selected in it.
            Button("Copy") { clipPool.first { $0.id == "last" }.map(copy) }
                .keyboardShortcut("c")
                .disabled(state.lastClipboard.isEmpty || openClip != nil)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private typealias Clip = (id: String, text: String, direction: ClipboardHistory.Direction)

    /// The phone's last clipboard, then the copies before it from the history.
    private var clipPool: [Clip] {
        let last = state.lastClipboard
        var rows: [Clip] = last.isEmpty ? [] : [("last", last, .received)]
        rows += clips.entries.filter { $0.text != last }.prefix(Self.clipPoolSize - rows.count)
            .map { ($0.id.uuidString, $0.text, $0.direction) }
        return rows
    }

    /// Back onto the Mac clipboard WITHOUT sending it to the phone again (see `restore`).
    private func copy(_ clip: Clip) {
        Task {
            await ClipboardWatcher.shared.restore(clip.text)
            copiedClip = clip.id
            try? await Task.sleep(for: .milliseconds(1200))
            if copiedClip == clip.id { copiedClip = nil }
        }
    }

    /// A binding, not `inout`: an inout argument is written back after the function returns,
    /// outside `withAnimation`, and the row then opened without any animation.
    private func toggle(_ open: Binding<String?>, _ id: String) {
        withAnimation(reduceMotion ? nil : Self.unfold) {
            open.wrappedValue = open.wrappedValue == id ? nil : id
        }
    }

    /// A section's name as a button to its full history in the window, with a chevron as Control
    /// Center's module titles have, then the section's one quiet action.
    private func sectionHeader(_ title: LocalizedStringKey, count: Int? = nil,
                               @ViewBuilder extra: () -> some View = { EmptyView() },
                               openWindow: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.small) {
            Button(action: openWindow) {
                HStack(spacing: Theme.Space.tight) {
                    Text(title).font(Theme.Font.heading)
                    if let count {
                        Text(verbatim: "\(count)")
                            .font(Theme.Font.label.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    Image(systemName: "chevron.right")
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in window")
            Spacer(minLength: Theme.Space.small)
            extra()
        }
    }

    /// Under a list that has more than it shows: "Show 3 more", or "Show less" once grown.
    @ViewBuilder
    private func moreRow(hidden: Int, grown: Binding<Bool>) -> some View {
        if hidden > 0 || grown.wrappedValue {
            Button {
                withAnimation(reduceMotion ? nil : Self.unfold) { grown.wrappedValue.toggle() }
            } label: {
                HStack(spacing: Theme.Space.tight) {
                    Text(grown.wrappedValue ? String(localized: "Show less") : String(localized: "Show \(hidden) more"))
                    Image(systemName: grown.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(Theme.Font.caption.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                    Spacer(minLength: 0)
                }
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
        }
    }

    /// A list at its own height, scrolling once grown past `listMax`. Fixed height: inside
    /// `.menuBarExtraStyle(.window)` a list with a flexible height collapses the second time the
    /// panel is opened.
    private func grownList(_ height: CGFloat, scrolls: Bool, @ViewBuilder rows: () -> some View) -> some View {
        // Room at the sides inside the scroll view for the rows' highlight, which reaches past the
        // text column: the scroll view clips, and it squared the highlight's corners off.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { rows() }
                .padding(.horizontal, Self.highlightBleed)
        }
        .padding(.horizontal, -Self.highlightBleed)
        // Scrolls whenever the rows pass the cap: an unfolded row can push them past it unasked.
        .scrollDisabled(height <= Self.listMax)
        .scrollIndicators(.automatic)
        .softScrollEdges()
        .frame(height: min(height, Self.listMax), alignment: .top)
    }

    // MARK: notifications

    private var shownNotifications: [NotificationHistory.Entry] {
        Array(history.entries.prefix(allNotifications ? Self.notificationsMax : recentCount))
    }

    private var notifications: some View {
        let rows = shownNotifications
        return VStack(alignment: .leading, spacing: Theme.Space.tight) {
            sectionHeader("Notifications", count: history.entries.isEmpty ? nil : history.entries.count,
                          extra: {
                              if !history.entries.isEmpty {
                                  QuietButton(String(localized: "Clear")) { history.clear() }
                              }
                          }) {
                state.showMainWindow(.notifications)
            }

            if rows.isEmpty {
                Text("No notifications yet")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .frame(height: ClipRow.foldedHeight)
            } else {
                grownList(rows.map { NotificationRow.height($0, open: openRow == $0.id) }.reduce(0, +),
                          scrolls: allNotifications) {
                    ForEach(rows) { entry in
                        NotificationRow(entry: entry, open: openRow == entry.id) { toggle($openRow, entry.id) }
                    }
                }
                // A new notification slides in at the top while the oldest of the four leaves at the
                // bottom, so the list keeps its height and the menu bar window never resizes.
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: rows.map(\.id))
            }
            moreRow(hidden: min(history.entries.count, Self.notificationsMax) - rows.count, grown: $allNotifications)
        }
    }

    // MARK: footer

    /// Settings and Quit as the panel's other controls: a glass capsule and a glass circle.
    private var footer: some View {
        HStack(spacing: Theme.Space.small) {
            Button {
                state.showSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(Theme.Font.label)
            }
            .buttonBorderShape(.capsule)
            .secondaryAction()
            .controlSize(.small)
            .keyboardShortcut(",", modifiers: .command)
            .help("Open Settings")

            Spacer(minLength: 0)

            IconButton(symbol: "power", label: String(localized: "Quit AndroMac")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .glassGroup()
    }
}

