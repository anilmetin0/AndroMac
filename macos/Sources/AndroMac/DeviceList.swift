import AndroMacKit
import SwiftUI

/// Every paired phone, connected or not, each one openable.
///
/// One code path for one phone and for several: with a single device its row is expanded already,
/// which is exactly the panel this app has always shown. Nothing is hidden behind a count check.
///
/// The list joins the two halves of the model — `Store.pairedDevices` is trust, written to disk and
/// outliving any connection; `AppState.devices` is reachability, which exists only while a session
/// does. A phone in the first list and not the second is simply offline, and saying so is more
/// useful than omitting it.
struct DeviceList: View {

    @EnvironmentObject private var state: AppState
    @Binding var expanded: Set<String>

    /// Re-read on each redraw: pairing and unpairing both change it, and it is a handful of items.
    /// `state.pairedDevicesChanged` is what makes that redraw happen after a write (see `Store`).
    private var paired: [PairedDevice] {
        _ = state.pairedDevicesChanged
        return Store.shared.pairedDevices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(paired) { device in
                DeviceRow(
                    device: device,
                    live: state.devices.first { $0.id == device.id },
                    expanded: isExpanded(device),
                    canCollapse: paired.count > 1,
                    toggle: { toggle(device) }
                )
                if device.id != paired.last?.id { Divider().opacity(0.4) }
            }
        }
    }

    /// A lone device is always open — there is nothing to choose between, so a disclosure arrow
    /// would only be a way to make the panel useless.
    private func isExpanded(_ device: PairedDevice) -> Bool {
        paired.count == 1 || expanded.contains(device.id)
    }

    private func toggle(_ device: PairedDevice) {
        guard paired.count > 1 else { return }
        if expanded.contains(device.id) {
            expanded.remove(device.id)
        } else {
            expanded.insert(device.id)
        }
    }
}

private struct DeviceRow: View {

    let device: PairedDevice
    let live: AppState.DeviceState?
    let expanded: Bool
    let canCollapse: Bool
    let toggle: () -> Void

    private var connected: Bool { live != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded { details }
        }
    }

    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 9) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)

                VStack(alignment: .leading, spacing: 1) {
                    Text(AppState.displayName(live?.name ?? device.name) ?? String(localized: "Phone"))
                        .font(Theme.Font.heading)
                        .lineLimit(1)
                    Text(statusLine)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if let battery = live?.battery {
                    Text("\(battery.level)%")
                        .font(Theme.Font.label.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if canCollapse {
                    Image(systemName: "chevron.right")
                        .font(Theme.Font.micro)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(device.name), \(statusLine)")
    }

    /// Three states worth telling apart, in the vocabulary Syncthing settled on: a disconnected
    /// device is not broken, and an offline one is not rejected.
    private var statusLine: String {
        if device.paused { return String(localized: "Disconnected") }
        if connected { return String(localized: "Connected") }
        return String(localized: "Offline")
    }

    private var dotColor: Color {
        if device.paused { return .secondary.opacity(0.5) }
        return connected ? .green : .orange
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The battery belongs to the device, not to the panel: with two phones open, one bar
            // at the bottom of the card could only ever describe one of them.
            if let battery = live?.battery, Store.shared.syncBattery {
                BatteryBar(battery: battery)
            }

            if let media = live?.media, Store.shared.syncMedia {
                MediaRow(media: media)
            }

            if connected, let system = live?.system {
                PhoneControls(deviceID: device.id, system: system)
            }

            clipboardToggle

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if connected, live?.caps.contains("system") == true { testNotificationButton }
                if connected, live?.caps.contains("find_phone") == true { ringButton }
                connectionButton
            }
        }
        .padding(.leading, 18)
    }

    /// Which phones get the Mac's clipboard is a per-device answer, so it belongs on the device.
    private var clipboardToggle: some View {
        Toggle(isOn: Binding(
            get: { device.receivesClipboard },
            set: { on in Store.shared.updateDevice(id: device.id) { $0.receivesClipboard = on } }
        )) {
            Text("Send my clipboard here")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private var ringButton: some View {
        Button {
            Task { await Server.shared.send(["t": "find_phone"], to: device.id) }
        } label: {
            Image(systemName: "bell.and.waves.left.and.right")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Ring this phone")
        .accessibilityLabel("Ring this phone")
    }

    /// Proves the whole notification chain in one click: the phone posts a notification to itself,
    /// its listener picks it up and it comes back here. If nothing appears, the missing piece is on
    /// the phone, which is a far more useful answer than a settings screen full of green ticks.
    private var testNotificationButton: some View {
        Button {
            Task {
                await Server.shared.send(
                    ["t": "system_control", "cmd": "test_notification"], to: device.id
                )
            }
        } label: {
            Image(systemName: "bell.badge")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Send a test notification from this phone")
        .accessibilityLabel("Send a test notification")
    }

    /// Disconnect hangs up and keeps the phone from coming back; Connect lets it in again.
    ///
    /// It used to say "Pause", which is what the flag is called on disk, and people read that as
    /// "stop syncing for a moment" rather than "hang up now" — which is exactly what it does.
    private var connectionButton: some View {
        QuietButton(device.paused ? String(localized: "Connect") : String(localized: "Disconnect")) {
            Store.shared.updateDevice(id: device.id) { $0.paused.toggle() }
            // Disconnecting has to hang up as well as refuse the next attempt, or the phone stays
            // on the line until something else drops it. Reconnecting is the phone's job: it
            // retries on its own backoff (PROTOCOL §1), the Mac only stops turning it away.
            if Store.shared.device(id: device.id)?.paused == true {
                Task { await Server.shared.disconnect(device.id) }
            }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            volume
            ringer
        }
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: level == 0 ? "speaker.slash" : "speaker.wave.2")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)

            Slider(
                value: Binding(get: { dragging ?? Double(system.volume) },
                               set: { dragging = $0 }),
                in: 0...Double(max(system.volumeMax, 1)),
                step: 1,
                onEditingChanged: { editing in
                    guard !editing, let value = dragging else { return }
                    dragging = nil
                    send("volume", level: Int(value.rounded()))
                }
            )
            .controlSize(.mini)

            Text("\(percent)%")
                .font(Theme.Font.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .accessibilityLabel("Phone volume")
    }

    private var level: Int { Int((dragging ?? Double(system.volume)).rounded()) }

    private var percent: Int {
        system.volumeMax > 0 ? level * 100 / system.volumeMax : 0
    }

    private var ringer: some View {
        HStack(spacing: 6) {
            ringerButton("normal", symbol: "bell", label: String(localized: "Ring"))
            ringerButton("vibrate", symbol: "iphone.radiowaves.left.and.right",
                         label: String(localized: "Vibrate"))
            ringerButton("silent", symbol: "bell.slash", label: String(localized: "Silent"))
            Spacer(minLength: 0)
            if !system.canSilence {
                // Android refuses a silent ringer to an app without Do Not Disturb access, so say
                // where the switch is instead of letting the button fail quietly.
                Text("Allow Do Not Disturb access on the phone to silence it")
                    .font(Theme.Font.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ringerButton(_ mode: String, symbol: String, label: String) -> some View {
        let selected = system.ringer == mode
        // Silencing is the one mode that needs the extra grant; the other two always work.
        let enabled = mode == "normal" || mode == "vibrate" || system.canSilence
        return Button {
            send("ringer", mode: mode)
        } label: {
            Image(systemName: symbol)
                .font(Theme.Font.label)
                .frame(width: 26, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.14))
                )
                .foregroundStyle(selected ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(label)
        .accessibilityLabel(label)
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
