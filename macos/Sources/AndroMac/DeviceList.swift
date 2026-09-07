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
    private var paired: [PairedDevice] { Store.shared.pairedDevices }

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

    /// Three states worth telling apart, in the vocabulary Syncthing settled on: a paused device is
    /// not broken, and an offline one is not rejected.
    private var statusLine: String {
        if device.paused { return String(localized: "Paused") }
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
            if let media = live?.media, Store.shared.syncMedia {
                MediaRow(media: media)
            }

            HStack(spacing: 10) {
                clipboardToggle
                Spacer(minLength: 0)
                if connected, live?.caps.contains("find_phone") == true {
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
                pauseButton
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

    private var pauseButton: some View {
        QuietButton(device.paused ? String(localized: "Resume") : String(localized: "Pause")) {
            Store.shared.updateDevice(id: device.id) { $0.paused.toggle() }
            // Pausing has to hang up as well as refuse the next attempt, or the phone stays on the
            // line until something else drops it.
            if Store.shared.device(id: device.id)?.paused == true {
                Task { await Server.shared.disconnect(device.id) }
            }
        }
    }
}
