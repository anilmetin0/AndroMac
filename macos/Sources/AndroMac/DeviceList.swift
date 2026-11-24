import AndroMacKit
import SwiftUI

/// Every paired phone, connected or not, one at a time.
///
/// With one phone the card is that phone. With several, a switcher across the top names them and
/// the card below is the selected one: the same layout whether there is one phone or five.
///
/// Switching never moves anything. The switcher has a fixed height, the card keeps the height of
/// the tallest phone's, and nothing is animated: the opacity transition this used to run kept the
/// old and the new card in the stack at the same time, the panel grew for the length of the
/// animation, and the menu bar window resizing under it is what left a gap above the switcher.
///
/// The list joins the two halves of the model: `Store.pairedDevices` is trust, written to disk and
/// outliving any connection; `AppState.devices` is reachability, which exists only while a session
/// does. A phone in the first list and not the second is offline, and saying so is more useful
/// than omitting it.
struct DeviceList: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Re-read on each redraw: pairing and unpairing both change it, and it is a handful of items.
    /// `state.pairedDevicesChanged` is what makes that redraw happen after a write (see `Store`).
    private var paired: [PairedDevice] {
        _ = state.pairedDevicesChanged
        return Store.shared.pairedDevices
    }

    /// The phone that is open. It follows the focused device, so switching also decides which
    /// phone the clipboard and file buttons under the card talk to.
    private var selected: PairedDevice? {
        paired.first { $0.id == state.focusedDeviceID } ?? paired.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            // Navigation, so it sits on the panel above the card, not inside it.
            if paired.count > 1 { switcher }
            // Every phone's card is laid out and only the open one is shown, so the card is always
            // as tall as the tallest and the panel keeps its height when the phone changes.
            if let selected {
                ZStack(alignment: .topLeading) {
                    ForEach(paired) { device in
                        let isOpen = device.id == selected.id
                        DeviceCard(device: device, live: live(device))
                            // Every card fills the tallest one's height, so the actions row
                            // sits at the bottom edge on every phone.
                            .frame(maxHeight: .infinity, alignment: .top)
                            .opacity(isOpen ? 1 : 0)
                            // A crossfade: both cards stay laid out, so the panel keeps its height.
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isOpen)
                            .allowsHitTesting(isOpen)
                            .disabled(!isOpen)
                            .accessibilityHidden(!isOpen)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func select(_ id: String) {
        state.focusedDeviceID = id
        state.refocus()
    }

    private func live(_ device: PairedDevice) -> AppState.DeviceState? {
        state.devices.first { $0.id == device.id }
    }

    /// Up to three phones: segments under a glass thumb that can be held and dragged across them,
    /// as the system's own on macOS 26. More would not fit a readable name, so they become a menu.
    @ViewBuilder
    private var switcher: some View {
        if paired.count > 3 {
            Picker("Phone", selection: Binding(get: { selected?.id ?? "" }, set: { select($0) })) {
                ForEach(paired) { device in
                    Text(DeviceCard.name(device, live(device))).tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } else {
            PhoneSwitcher(phones: paired.map { ($0.id, DeviceCard.name($0, live($0))) },
                          selected: selected?.id ?? "", select: select)
        }
    }
}

/// The phone segments. The thumb follows the pointer while it is held, then settles on the phone
/// under it; a click on a name moves it there. Only the release changes the phone below, so a
/// drag across does not flash every card on the way.
private struct PhoneSwitcher: View {
    let phones: [(id: String, name: String)]
    let selected: String
    let select: (String) -> Void

    /// The pointer's x while the thumb is held.
    @State private var dragX: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let height: CGFloat = 28
    private static let inset: CGFloat = 2
    /// How far the held thumb grows on each side.
    private static let grow: CGFloat = 4

    private var held: Bool { dragX != nil }

    var body: some View {
        GeometryReader { geo in
            let width = (geo.size.width - 2 * Self.inset) / CGFloat(phones.count)
            let index = phones.firstIndex { $0.id == selected } ?? 0
            let x = dragX.map { min(max($0 - width / 2, 0), geo.size.width - 2 * Self.inset - width) }
                ?? CGFloat(index) * width
            ZStack(alignment: .leading) {
                // Placed by layout, not `offset`: glass is drawn where the view is laid out, and
                // an offset thumb stayed under the first phone.
                // Held, it grows a little past the track and lifts, as the system's thumb does;
                // by its frame, since a scale effect is not applied to glass either.
                thumb
                    .frame(width: width + (held ? Self.grow * 2 : 0),
                           height: geo.size.height - 2 * Self.inset + (held ? Self.grow * 2 : 0))
                    .padding(.leading, x - (held ? Self.grow : 0))
                HStack(spacing: 0) {
                    ForEach(Array(phones.enumerated()), id: \.element.id) { i, phone in
                        Text(phone.name)
                            .font(Theme.Font.label.weight(i == index ? .semibold : .regular))
                            .foregroundStyle(i == index ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, Theme.Space.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityAddTraits(i == index ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { select(phone.id) }
                    }
                }
            }
            .padding(Self.inset)
            // Centred in the track: a GeometryReader pins its content to the top, and the held
            // thumb grew downwards only. Centred, it grows from its middle, as the system's does.
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragX = $0.location.x - Self.inset }
                    .onEnded { value in
                        let i = min(max(Int((value.location.x - Self.inset) / width), 0), phones.count - 1)
                        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78)) {
                            dragX = nil
                            select(phones[i].id)
                        }
                    }
            )
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: dragX == nil)
        }
        .frame(height: Self.height)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Phone")
    }

    /// Liquid Glass on 26+, which lights up under the pointer while held; a raised fill before.
    @ViewBuilder
    private var thumb: some View {
        if #available(macOS 26.0, *) {
            Capsule().fill(.clear)
                .glassEffect(held ? .clear.interactive() : .regular.interactive(), in: Capsule())
                .shadow(color: .black.opacity(held ? 0.18 : 0), radius: 6, y: 2)
        } else {
            Capsule().fill(Color.primary.opacity(0.14))
                .shadow(color: .black.opacity(held ? 0.25 : 0.15), radius: held ? 5 : 2, y: 1)
        }
    }
}

/// The selected phone, top to bottom: who, state and battery on one line, the track and volume,
/// then one row of actions. Everything secondary is one click further, in the More menu.
private struct DeviceCard: View {

    let device: PairedDevice
    let live: AppState.DeviceState?
    @EnvironmentObject private var state: AppState
    @ObservedObject private var mirror = ScreenMirror.shared

    private var connected: Bool { live != nil }

    static func name(_ device: PairedDevice, _ live: AppState.DeviceState?) -> String {
        AppState.displayName(live?.name ?? device.name) ?? String(localized: "Phone")
    }

    private var title: String { Self.name(device, live) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            header

            // The track while the phone has one, paused too, so Play is one click away; the volume
            // only while it plays.
            if let media = live?.media, Store.shared.syncMedia {
                MediaRow(media: media, deviceID: device.id)
                if media.playing, let system = live?.system {
                    PhoneControls(deviceID: device.id, system: system)
                }
            }

            if connected {
                MirrorStatus(deviceID: device.id, name: title,
                             canOpenOnPhone: live?.caps.contains("debugging") == true)
            } else {
                // Paired but not here: almost every connection problem is one of these two things.
                // The Mac only listens (PROTOCOL §1), so there is nothing to click for it: the
                // phone dials in as soon as both are true. Connect here turns the switch back on
                // and knocks, so a phone parked with its own switch off dials in and hears of it.
                // Offline there is little to act on, so it sits on this line instead of taking a
                // row of its own.
                HStack(spacing: Theme.Space.small) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let lastSeen = device.lastSeen {
                            TimelineView(.everyMinute) { context in
                                Text("Last seen \(RelativeTime.string(lastSeen, now: context.date))")
                            }
                        }
                        Group {
                            if device.paused {
                                Text("To use it again, click Connect.")
                            } else if device.awaitsConnectOnPhone {
                                Text("If it does not connect, tap Connect on the phone.")
                            } else {
                                Text("Open AndroMac on the phone, on the same Wi‑Fi.")
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    // fixedSize: beside a two-line hint the controls were squeezed to half their size.
                    HStack(spacing: Theme.Space.small) {
                        if device.paused {
                            Button("Connect", action: connect)
                                .secondaryAction()
                                .controlSize(.small)
                        }
                        more
                    }
                    .fixedSize()
                    .glassGroup()
                }
            }

            Spacer(minLength: 0)
            if connected { actions }
        }
    }

    /// Who, what state and the battery on one line. Clicking the name opens this phone's entry
    /// in Settings.
    private var header: some View {
        HStack(spacing: Theme.Space.small) {
            Button {
                state.showMainWindow(.setting(.devices))
            } label: {
                HStack(spacing: Theme.Space.small) {
                    Circle()
                        .fill(Self.dotColor(device: device, connected: connected))
                        .frame(width: 8, height: 8)
                    Text(title)
                        .font(Theme.Font.heading)
                        .lineLimit(1)
                    // A long name truncates; the state beside it stays whole.
                    Text(statusLine)
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The address only on hover: it tells two phones apart without crowding the line.
            .help(address.map { Text("Open device settings") + Text(verbatim: " · \($0)") } ?? Text("Open device settings"))
            .accessibilityLabel("\(title), \(statusLine)")
            Spacer(minLength: Theme.Space.tight)
            // The ringer one click away, showing the mode it is in: in More it was three lines of
            // a long menu.
            if connected, let system = live?.system {
                GlassMenuButton(symbol: PhoneControls.symbol(system.ringer), label: String(localized: "Ringer")) {
                    [.header(String(localized: "Ringer"))] + PhoneControls.ringerItems(deviceID: device.id, system: system)
                }
                .accessibilityValue(Text(PhoneControls.label(system.ringer)))
            }
            // The battery belongs to the device, not to the panel: with two phones, one line at
            // the bottom could only ever describe one of them.
            if let battery = live?.battery, Store.shared.syncBattery {
                BatteryLine(battery: battery)
            }
        }
    }

    private var address: String? { live?.host ?? device.lastAddress }

    /// Three states worth telling apart: a phone kept away is not broken, and an offline one is
    /// not rejected. With auto-connect off the link can still be up (Connect on the phone, or the
    /// switch turned off mid-session), so being connected is said first.
    private var statusLine: String {
        if connected { return String(localized: "Connected") }
        if device.paused { return String(localized: "Auto-connect off") }
        return String(localized: "Offline")
    }

    static func dotColor(device: PairedDevice, connected: Bool) -> Color {
        if connected { return .green }
        return device.paused ? .secondary.opacity(0.5) : .orange
    }

    /// Compact glass capsules, each with its name: icons alone left look-alike symbols side by
    /// side. More is the round button at the end, like the system's own overflow.
    private var actions: some View {
        HStack(spacing: Theme.Space.tight + Theme.Space.hair) {
            if live?.caps.contains("find_phone") == true {
                ActionTile(symbol: "bell", title: String(localized: "Ring"),
                           help: String(localized: "Ring this phone")) {
                    Task { await Server.shared.send(["t": "find_phone"], to: device.id) }
                }
            }
            if live?.caps.contains("sms") == true {
                ActionTile(symbol: "message", title: String(localized: "Messages"),
                           help: String(localized: "Open messages")) {
                    state.showMessages(for: device.id)
                }
            }
            mirrorButton
            Spacer(minLength: 0)
            more
        }
        .glassGroup()
    }

    private var mirrorButton: some View {
        let running = mirror.phase(device.id) == .running
        let label = running ? String(localized: "Stop mirroring") : String(localized: "Mirror this phone's screen")
        return ActionTile(symbol: running ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle",
                          title: running ? String(localized: "Stop") : String(localized: "Screen"),
                          help: label, active: running) {
            mirror.toggle(deviceID: device.id, host: live?.host, title: title)
        }
        .disabled(mirror.phase(device.id).busy)
    }

    /// The per-phone switches, Disconnect and Forget: reachable, but out of the way of a glance.
    /// Disconnect only while the phone is connected.
    private var more: some View {
        GlassMenuButton(symbol: "ellipsis", label: String(localized: "More")) { moreItems }
    }

    private var moreItems: [PanelMenu.Item] {
        var items: [PanelMenu.Item] = []
        // Proves the whole notification chain in one click: the phone posts a notification to
        // itself, its listener picks it up and it comes back here.
        if connected, live?.caps.contains("system") == true {
            items += [.action(String(localized: "Send a test notification from this phone"), symbol: "app.badge") {
                Task { await Server.shared.send(["t": "system_control", "cmd": "test_notification"], to: device.id) }
            }, .separator]
        }
        items += [
            // Which phones get the Mac's clipboard is a per-device answer, so it belongs here.
            .action(String(localized: "Send my clipboard here"), symbol: "doc.on.clipboard",
                    checked: device.receivesClipboard) {
                Store.shared.updateDevice(id: device.id) { $0.receivesClipboard.toggle() }
            },
            // The same switch as on the phone: flipping either flips both (PROTOCOL §3).
            .action(String(localized: "Connect automatically"), symbol: "arrow.triangle.2.circlepath",
                    checked: !device.paused) {
                let on = device.paused
                Task { await Server.shared.setAutoConnect(on, for: device.id) }
            },
            .action(String(localized: "Device settings…"), symbol: "gearshape") {
                state.showMainWindow(.setting(.devices))
            },
            .separator,
        ]
        // Only a phone on the line can be hung up on; offline, Disconnect did nothing visible.
        if connected {
            items.append(.action(String(localized: "Disconnect"), symbol: "xmark.circle", run: disconnect))
        }
        // The same as Forget in Settings, asked first: undoing it means pairing again.
        items.append(.action(String(localized: "Forget…"), symbol: "trash", destructive: true, run: confirmForget))
        return items
    }

    private func confirmForget() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Forget \(title)?")
        alert.informativeText = String(localized: "To use it with this Mac again, pair it again.")
        alert.addButton(withTitle: String(localized: "Forget")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Store.shared.unpair(id: device.id)
        Task { await Server.shared.disconnect(device.id) }
    }

    /// Like the phone's Disconnect: hang up and turn auto-connect off on both sides, so the phone
    /// stays away until someone taps Connect on it or clicks Connect here.
    private func disconnect() {
        Task { await Server.shared.hangUp(device.id) }
    }

    /// The Mac only listens (PROTOCOL §1): this turns auto-connect back on here and knocks. The
    /// phone, parked with its own switch off, dials in once and takes the newer switch.
    private func connect() {
        Task { await Server.shared.setAutoConnect(true, for: device.id) }
    }
}

// MARK: - screen mirroring

/// What screen mirroring needs from the user, one line and at most one field. Hidden while idle
/// or running: the button already says which.
private struct MirrorStatus: View {

    let deviceID: String
    let name: String
    let canOpenOnPhone: Bool
    @ObservedObject private var mirror = ScreenMirror.shared
    @State private var code = ""

    var body: some View {
        let phase = mirror.phase(deviceID)
        if let message = message(phase) {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                    if phase.busy { ProgressView().controlSize(.mini) }
                    Text(message)
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if !phase.busy {
                        Button { mirror.dismiss(deviceID) } label: {
                            Image(systemName: "xmark").font(Theme.Font.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Dismiss")
                    }
                }
                actions(phase)
            }
        }
    }

    private func message(_ phase: ScreenMirror.Phase) -> String? {
        switch phase {
        case .idle, .running: return nil
        case .starting: return String(localized: "Connecting to \(name)…")
        case .needsDebugging:
            return String(localized: "Turn on Wireless debugging on the phone, or connect it with a USB cable.")
        case .needsPairing:
            return String(localized: "On the phone, open Wireless debugging → Pair device with pairing code, and enter the code here.")
        case .needsApproval: return String(localized: "Allow USB debugging on the phone.")
        case .notInstalled: return String(localized: "Screen mirroring needs scrcpy: brew install scrcpy")
        case .failed(let reason): return reason
        }
    }

    @ViewBuilder
    private func actions(_ phase: ScreenMirror.Phase) -> some View {
        switch phase {
        case .needsPairing:
            HStack(spacing: Theme.Space.small) {
                TextField("Pairing code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.body.monospacedDigit())
                    .frame(width: 96)
                    .onSubmit(pair)
                Button("Pair", action: pair)
                    .controlSize(.small)
                    .disabled(code.filter(\.isNumber).count != 6)
            }
        case .needsDebugging:
            HStack(spacing: Theme.Space.medium) {
                if canOpenOnPhone {
                    QuietButton(String(localized: "Open on phone")) {
                        Task {
                            await Server.shared.send(["t": "system_control", "cmd": "open_debugging"], to: deviceID)
                        }
                    }
                }
                QuietButton(String(localized: "Try again")) { mirror.retry(deviceID) }
            }
        case .needsApproval, .failed:
            QuietButton(String(localized: "Try again")) { mirror.retry(deviceID) }
        case .idle, .starting, .running, .notInstalled:
            EmptyView()
        }
    }

    private func pair() {
        guard code.filter(\.isNumber).count == 6 else { return }
        mirror.pair(deviceID: deviceID, code: code)
        code = ""
    }
}

// MARK: - phone controls

/// Ringer and volume, the two things people reach for the phone to change while it is in the next
/// room. Both are one message to the phone (`system_control`); the phone reports the result back
/// with `system`, so what is on screen is always the phone's own state rather than our guess.
private struct PhoneControls: View {

    let deviceID: String
    let system: AppState.PhoneSystem

    /// The slider's live value while dragging. Committed on release: sending on every frame would
    /// put a hundred messages on the wire for one gesture.
    @State private var dragging: Double?

    /// The volume, while something plays. The ringer mode is its own button on the phone's line.
    var body: some View {
        HStack(spacing: Theme.Space.small) {
            Image(systemName: "speaker.fill")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            // No `step`: a stepped macOS slider draws a tick mark per step. The value is rounded
            // when it is sent instead.
            Slider(
                value: Binding(get: { dragging ?? Double(system.volume) },
                               set: { dragging = $0 }),
                in: 0...Double(max(system.volumeMax, 1)),
                onEditingChanged: { editing in
                    guard !editing, let value = dragging else { return }
                    dragging = nil
                    Self.send("volume", level: Int(value.rounded()), to: deviceID)
                }
            )
            .controlSize(.small)
            .accessibilityLabel("Phone volume")
            .accessibilityValue("\(percent)%")
            Image(systemName: "speaker.wave.3.fill")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var level: Int { Int((dragging ?? Double(system.volume)).rounded()) }

    private var percent: Int {
        system.volumeMax > 0 ? level * 100 / system.volumeMax : 0
    }

    private static let modes: [(mode: String, symbol: String, label: String.LocalizationValue)] = [
        ("normal", "bell", "Ring"),
        ("vibrate", "iphone.radiowaves.left.and.right", "Vibrate"),
        ("silent", "bell.slash", "Silent"),
    ]

    static func symbol(_ ringer: String) -> String {
        (modes.first { $0.mode == ringer } ?? modes[0]).symbol
    }

    static func label(_ ringer: String) -> String {
        String(localized: (modes.first { $0.mode == ringer } ?? modes[0]).label)
    }

    /// The ringer modes as menu items, the current one checked.
    static func ringerItems(deviceID: String, system: AppState.PhoneSystem) -> [PanelMenu.Item] {
        var items: [PanelMenu.Item] = modes.map { option in
            // Silencing is the one mode that needs the extra grant; the other two always work.
            .action(String(localized: option.label), symbol: option.symbol,
                    checked: system.ringer == option.mode,
                    enabled: option.mode != "silent" || system.canSilence) {
                send("ringer", mode: option.mode, to: deviceID)
            }
        }
        if !system.canSilence {
            // Android refuses a silent ringer to an app without Do Not Disturb access, so say
            // where the switch is instead of letting the item fail quietly.
            items += [.note(String(localized: "Allow Do Not Disturb access on the phone to silence it"))]
        }
        return items
    }

    /// The message is built inside the task: a dictionary of `Any` cannot cross an actor boundary,
    /// and the two values it carries are plain.
    private static func send(_ cmd: String, mode: String? = nil, level: Int? = nil, to deviceID: String) {
        Task {
            var msg: [String: Any] = ["t": "system_control", "cmd": cmd]
            if let mode { msg["mode"] = mode }
            if let level { msg["level"] = level }
            await Server.shared.send(msg, to: deviceID)
        }
    }
}
