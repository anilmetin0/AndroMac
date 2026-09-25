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
            if paired.count > 1 { switcher.frame(height: Self.switcherHeight) }
            // Every phone's card is laid out and only the open one is shown, so the card is always
            // as tall as the tallest and the panel keeps its height when the phone changes.
            if let selected {
                PanelCard {
                    ZStack(alignment: .topLeading) {
                        ForEach(paired) { device in
                            let isOpen = device.id == selected.id
                            DeviceCard(device: device, live: live(device))
                                // Every card fills the tallest one's height, so the actions row
                                // sits at the bottom edge on every phone.
                                .frame(maxHeight: .infinity, alignment: .top)
                                .opacity(isOpen ? 1 : 0)
                                .allowsHitTesting(isOpen)
                                .disabled(!isOpen)
                                .accessibilityHidden(!isOpen)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static let switcherHeight: CGFloat = 28

    private func select(_ id: String) {
        state.focusedDeviceID = id
        state.refocus()
    }

    private func live(_ device: PairedDevice) -> AppState.DeviceState? {
        state.devices.first { $0.id == device.id }
    }

    /// Up to three phones: equal segments on one track, the open one on a raised pill. More than
    /// that would not fit a readable name, so it becomes a menu with the open phone's name on it.
    @ViewBuilder
    private var switcher: some View {
        if paired.count > 3, let selected {
            Menu {
                Picker("Phone", selection: Binding(get: { selected.id }, set: { select($0) })) {
                    ForEach(paired) { device in
                        Text(DeviceCard.name(device, live(device))).tag(device.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                DeviceSegment(device: selected, live: live(selected), selected: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panelCard(Color.primary.opacity(0.06))
            .help("Choose a phone")
        } else {
            HStack(spacing: 0) {
                ForEach(paired) { device in
                    let isOpen = device.id == selected?.id
                    Button { select(device.id) } label: {
                        DeviceSegment(device: device, live: live(device), selected: isOpen)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOpen ? .isSelected : [])
                }
            }
            .padding(Theme.Space.hair)
            // The track has the cards' corner, the open segment that corner minus the gap around
            // it: concentric with the panel like every other plate on it.
            .panelCard(Color.primary.opacity(0.06))
        }
    }
}

/// One segment: a status dot and the name, middle-truncated so two phones of the same model stay
/// apart. No battery here: the card below prints the open phone's, and only once.
private struct DeviceSegment: View {

    let device: PairedDevice
    let live: AppState.DeviceState?
    let selected: Bool

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            Circle()
                .fill(DeviceCard.dotColor(device: device, connected: live != nil))
                .frame(width: 6, height: 6)
            Text(DeviceCard.name(device, live))
                .font(Theme.Font.label.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, Theme.Space.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { if selected { pill } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DeviceCard.name(device, live))
    }

    /// Glass on 26+, a quiet raised fill before. Either way it only paints: the segment's size
    /// does not depend on being selected.
    @ViewBuilder
    private var pill: some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.card - Theme.Space.hair, style: .continuous)
            shape.fill(.clear).glassEffect(.regular.interactive(), in: shape)
        } else {
            Capsule().fill(Color.primary.opacity(0.12))
        }
    }
}

/// The selected phone, top to bottom: who and what state, battery, the track, ringer and volume,
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

            // The battery belongs to the device, not to the panel: with two phones, one line at
            // the bottom could only ever describe one of them.
            if let battery = live?.battery, Store.shared.syncBattery {
                BatteryLine(battery: battery)
            }

            if let media = live?.media, Store.shared.syncMedia {
                MediaRow(media: media, deviceID: device.id)
            }

            if connected, let system = live?.system {
                PhoneControls(deviceID: device.id, system: system)
            }

            if connected {
                MirrorStatus(deviceID: device.id, name: title,
                             canOpenOnPhone: live?.caps.contains("debugging") == true)
            } else if !device.paused {
                // Paired but not here: almost every connection problem is one of these two things.
                // The Mac only listens (PROTOCOL §1), so there is nothing to click for it: the
                // phone dials in as soon as both are true.
                // Offline there is nothing to act on but More, so it sits on this line instead of
                // taking a row of its own.
                HStack(spacing: Theme.Space.small) {
                    Text("Open AndroMac on the phone, on the same Wi‑Fi.")
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    more.glassGroup()
                }
            }

            Spacer(minLength: 0)
            if connected || device.paused { actions }
        }
    }

    /// Clicking the name opens this phone's entry in Settings.
    private var header: some View {
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
                Spacer(minLength: Theme.Space.tight)
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
        .help("Open device settings")
        .accessibilityLabel("\(title), \(statusLine)")
    }

    /// Three states worth telling apart, in the vocabulary Syncthing settled on: a disconnected
    /// device is not broken, and an offline one is not rejected.
    private var statusLine: String {
        if device.paused { return String(localized: "Disconnected") }
        if connected { return String(localized: "Connected") }
        return String(localized: "Offline")
    }

    static func dotColor(device: PairedDevice, connected: Bool) -> Color {
        if device.paused { return .secondary.opacity(0.5) }
        return connected ? .green : .orange
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.small) {
            if device.paused {
                Button("Connect", action: toggleConnection)
                    .secondaryAction()
                    .controlSize(.small)
            }
            if connected, live?.caps.contains("find_phone") == true {
                IconButton(symbol: "bell.and.waves.left.and.right",
                           label: String(localized: "Ring this phone")) {
                    Task { await Server.shared.send(["t": "find_phone"], to: device.id) }
                }
            }
            // Proves the whole notification chain in one click: the phone posts a notification to
            // itself, its listener picks it up and it comes back here.
            if connected, live?.caps.contains("system") == true {
                IconButton(symbol: "bell.badge",
                           label: String(localized: "Send a test notification from this phone")) {
                    Task {
                        await Server.shared.send(
                            ["t": "system_control", "cmd": "test_notification"], to: device.id
                        )
                    }
                }
            }
            if connected { mirrorButton }
            Spacer(minLength: 0)
            more
        }
        .glassGroup()
    }

    private var mirrorButton: some View {
        let running = mirror.phase(device.id) == .running
        let label = running ? String(localized: "Stop mirroring") : String(localized: "Mirror this phone's screen")
        return IconButton(symbol: running ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle",
                          label: label, active: running) {
            mirror.toggle(deviceID: device.id, host: live?.host, title: title)
        }
        .disabled(mirror.phase(device.id).busy)
    }

    /// The per-phone clipboard switch, Disconnect and Forget: reachable, but out of the way of a
    /// glance. Offered whatever the phone's state, offline included.
    private var more: some View {
        Menu {
            // Which phones get the Mac's clipboard is a per-device answer, so it belongs here.
            Toggle("Send my clipboard here", isOn: Binding(
                get: { device.receivesClipboard },
                set: { on in Store.shared.updateDevice(id: device.id) { $0.receivesClipboard = on } }
            ))
            Button("Device settings…") { state.showMainWindow(.setting(.devices)) }
            Divider()
            if !device.paused {
                Button("Disconnect", action: toggleConnection)
            }
            // The same as Forget in Settings: this phone only, hung up on at once.
            Button("Forget", role: .destructive) {
                Store.shared.unpair(id: device.id)
                Task { await Server.shared.disconnect(device.id) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Theme.Font.label)
                .frame(width: 16, height: 16)
        }
        .glassMenu()
        .help("More")
        .accessibilityLabel("More")
    }

    /// Disconnect hangs up and keeps the phone from coming back; Connect lets it in again.
    private func toggleConnection() {
        Store.shared.updateDevice(id: device.id) { $0.paused.toggle() }
        // Disconnecting has to hang up as well as refuse the next attempt, or the phone stays on
        // the line until something else drops it. Reconnecting is the phone's job: it retries on
        // its own backoff (PROTOCOL §1), the Mac only stops turning it away.
        if Store.shared.device(id: device.id)?.paused == true {
            Task { await Server.shared.disconnect(device.id) }
        }
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

    /// One row, Control Center style: the ringer mode as a single menu, then the volume.
    var body: some View {
        HStack(spacing: Theme.Space.small) {
            ringer
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
                    send("volume", level: Int(value.rounded()))
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

    private static let modes: [(mode: String, symbol: String, label: LocalizedStringKey)] = [
        ("normal", "bell", "Ring"),
        ("vibrate", "iphone.radiowaves.left.and.right", "Vibrate"),
        ("silent", "bell.slash", "Silent"),
    ]

    private var current: (mode: String, symbol: String, label: LocalizedStringKey) {
        Self.modes.first { $0.mode == system.ringer } ?? Self.modes[0]
    }

    private var ringer: some View {
        Menu {
            ForEach(Self.modes, id: \.mode) { option in
                Toggle(isOn: Binding(
                    get: { system.ringer == option.mode },
                    set: { if $0 { send("ringer", mode: option.mode) } }
                )) {
                    Label(option.label, systemImage: option.symbol)
                }
                // Silencing is the one mode that needs the extra grant; the other two always work.
                .disabled(option.mode == "silent" && !system.canSilence)
            }
            if !system.canSilence {
                Divider()
                // Android refuses a silent ringer to an app without Do Not Disturb access, so say
                // where the switch is instead of letting the item fail quietly.
                Text("Allow Do Not Disturb access on the phone to silence it")
            }
        } label: {
            Image(systemName: current.symbol)
                .font(Theme.Font.label)
                .frame(width: 16, height: 16)
        }
        .glassMenu()
        .help("Ringer")
        .accessibilityLabel("Ringer")
        .accessibilityValue(current.label)
    }

    /// The message is built inside the task: a dictionary of `Any` cannot cross an actor boundary,
    /// and the two values it carries are plain.
    private func send(_ cmd: String, mode: String? = nil, level: Int? = nil) {
        let deviceID = deviceID
        Task {
            var msg: [String: Any] = ["t": "system_control", "cmd": cmd]
            if let mode { msg["mode"] = mode }
            if let level { msg["level"] = level }
            await Server.shared.send(msg, to: deviceID)
        }
    }
}
