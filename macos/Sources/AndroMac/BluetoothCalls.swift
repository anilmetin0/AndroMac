import AppKit
import AVFoundation
@preconcurrency import IOBluetooth
import SwiftUI
import UserNotifications

/// HFP uses the system Bluetooth pairing, independently of AndroMac's encrypted LAN session.
/// No Android polling, call-log permission or default-dialer replacement is needed.
@MainActor
final class BluetoothCalls: NSObject, ObservableObject, IOBluetoothHandsFreeDeviceDelegate {
    static let shared = BluetoothCalls()
    nonisolated static let notificationCategoryID = "andromac.calls"
    nonisolated static let answerAction = "andromac.call.answer"
    nonisolated static let declineAction = "andromac.call.decline"
    private var callToken = UUID().uuidString
    struct Phone: Identifiable { let id: String; let name: String }
    @Published private(set) var phones: [Phone] = []
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var incoming = false {
        didSet {
            guard incoming != oldValue else { return }
            guard !DemoMode.isOn else { return }
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [Self.notificationCategoryID])
            center.removePendingNotificationRequests(withIdentifiers: [Self.notificationCategoryID])
            callToken = UUID().uuidString
            if incoming {
                let content = UNMutableNotificationContent()
                content.title = phoneName
                content.body = String(localized: "Incoming call")
                content.categoryIdentifier = Self.notificationCategoryID
                content.userInfo = ["callToken": callToken]
                content.sound = .default
                center.add(UNNotificationRequest(identifier: Self.notificationCategoryID, content: content, trigger: nil))
            }
        }
    }
    @Published private(set) var active = false
    @Published private(set) var audioConnected = false
    @Published private(set) var phoneName = ""
    @Published private(set) var caller = ""
    @Published private(set) var error: String?
    @Published var selectedID = UserDefaults.standard.string(forKey: "callPhone") ?? ""
    private var handsFree: IOBluetoothHandsFreeDevice?
    private var timeout: Task<Void, Never>?
    private var audioTimeout: Task<Void, Never>?
    private var wantsMacAudio = false
    /// Set while a connected phone is bonding with this Mac on its own (`bt_pair`).
    @Published private(set) var pairing = false
    @Published private(set) var pairNote: String?
    private var pairedBefore: Set<String> = []
    private var pairTimeout: Task<Void, Never>?

    static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: notificationCategoryID, actions: [
            UNNotificationAction(identifier: answerAction, title: String(localized: "Answer"), options: [.foreground]),
            UNNotificationAction(identifier: declineAction, title: String(localized: "Decline"), options: [.destructive]),
        ], intentIdentifiers: [])
    }

    func notificationAction(_ action: String, token: String) {
        guard incoming, token == callToken else { return }
        if action == Self.answerAction { answer() }
        else if action == Self.declineAction { endCall() }
        else { AppState.shared.showMainWindow(.setting(.calls)) }
    }

    func bootstrap() {
        guard UserDefaults.standard.bool(forKey: "bluetoothCallsEnabled") else { return }
        refresh()
        connect()
    }

    func refresh() {
        guard !DemoMode.isOn else { return }
        // Listing is user-triggered, not a background discovery scan.
        phones = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap {
            guard let address = $0.addressString else { return nil }
            // A phone may not have cached SDP data yet; it can still be selected explicitly.
            return Phone(id: address, name: $0.name ?? address)
        }
        if selectedID.isEmpty { selectedID = phones.first?.id ?? "" }
    }

    /// Asks a phone with a live AndroMac session to bond with this Mac.
    ///
    /// Android keeps its own Bluetooth address from apps, so the phone has to dial the Mac. Its
    /// address goes over the encrypted link; both screens then show the system pairing code.
    func pair(with deviceID: String) {
        guard !DemoMode.isOn else { return }
        guard let host = IOBluetoothHostController.default(),
              host.powerState == kBluetoothHCIPowerStateON,
              let raw = host.addressAsString() else {
            error = String(localized: "Turn on Bluetooth on your Mac, then try again.")
            return
        }
        let address = raw.replacingOccurrences(of: "-", with: ":").uppercased()
        pairedBefore = Set(pairedAddresses())
        error = nil
        pairNote = String(localized: "Confirm the pairing code on your phone and your Mac.")
        pairing = true
        pairTimeout?.cancel()
        pairTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self, self.pairing else { return }
            self.pairFailed()
        }
        Task {
            if await !Server.shared.send(["t": "bt_pair", "addr": address], to: deviceID) { pairFailed() }
        }
    }

    /// `bt_pair_result` from the phone. `name` is its Bluetooth name, used only when the paired
    /// list did not grow (the phone was paired before) to find it among the Mac's devices.
    func pairResult(_ state: String, name: String) {
        guard pairing else { return }
        switch state {
        case "bonded":
            pairTimeout?.cancel(); pairTimeout = nil
            pairing = false; pairNote = nil
            refresh()
            let fresh = phones.first { !pairedBefore.contains($0.id) }
            if let phone = fresh ?? phones.first(where: { $0.name == name }) { selectedID = phone.id }
            connect()
        case "permission":
            pairNote = String(localized: "Allow Nearby devices on your phone from the AndroMac notification.")
        case "bluetooth_off":
            pairFailed(String(localized: "Turn on Bluetooth on your phone, then try again."))
        default:
            pairFailed()
        }
    }

    private func pairFailed(_ message: String? = nil) {
        pairTimeout?.cancel(); pairTimeout = nil
        pairing = false; pairNote = nil
        error = message ?? String(localized: "Pairing did not finish. Try again, or pair in Bluetooth settings.")
    }

    private func pairedAddresses() -> [String] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap(\.addressString)
    }

    func connect() {
        guard !DemoMode.isOn, let phone = phones.first(where: { $0.id == selectedID }),
              let device = IOBluetoothDevice(addressString: phone.id), device.isPaired() else { return }
        disconnect()
        guard let hf = IOBluetoothHandsFreeDevice(device: device, delegate: self) else {
            error = String(localized: "This phone does not support Bluetooth call control")
            return
        }
        handsFree = hf
        phoneName = phone.name
        error = nil
        connecting = true
        // Caller ID and call state; do not advertise codec or conference features we do not implement.
        hf.supportedFeatures = 1 << 2 | 1 << 5
        hf.connect()
        timeout = Task { [weak self, weak hf] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.handsFree === hf, !self.connected else { return }
            self.disconnect()
            self.error = String(localized: "Could not connect calls. Pair your phone in Bluetooth settings and try again.")
        }
    }

    func disconnect() {
        timeout?.cancel(); timeout = nil
        audioTimeout?.cancel(); audioTimeout = nil
        handsFree?.delegate = nil
        handsFree?.disconnect()
        handsFree = nil
        connected = false; connecting = false; incoming = false; active = false
        audioConnected = false; wantsMacAudio = false; caller = ""
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: "bluetoothCallsEnabled")
        disconnect()
    }

    func answer() {
        guard connected, incoming else { return }
        let answering = handsFree
        let token = callToken
        Task {
            guard await microphoneAllowed(), connected, incoming,
                  handsFree === answering, callToken == token else { return }
            wantsMacAudio = true
            handsFree?.acceptCall()
        }
    }

    func endCall() { guard connected else { return }; wantsMacAudio = false; handsFree?.endCall() }

    func useMacAudio() {
        guard connected, active else { return }
        let routing = handsFree
        let token = callToken
        Task {
            guard await microphoneAllowed(), connected, active,
                  handsFree === routing, callToken == token else { return }
            wantsMacAudio = true
            openAudio()
        }
    }

    func usePhoneAudio() {
        wantsMacAudio = false
        audioTimeout?.cancel(); audioTimeout = nil
        handsFree?.transferAudioToPhone()
    }

    private func microphoneAllowed() async -> Bool {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        if !allowed { error = String(localized: "Allow microphone access in System Settings to use call audio on your Mac") }
        return allowed
    }

    private func openAudio() {
        error = nil
        handsFree?.transferAudioToComputer()
        audioTimeout?.cancel()
        audioTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, !self.audioConnected, self.active else { return }
            self.audioFailed()
        }
    }

    private func audioFailed() {
        wantsMacAudio = false
        audioConnected = false
        handsFree?.transferAudioToPhone()
        error = String(localized: "macOS could not open Bluetooth call audio. Continue the call on your phone.")
    }

    private enum Event: Sendable {
        case connected(Int32), disconnected, callActive(Bool), setup(Int), incoming(String)
        case audioOpened(Int32), audioClosed
    }

    // IOBluetooth does not declare a callback queue. Move immutable values onto the main actor;
    // never send a framework device object between executors or accept an old connection's event.
    nonisolated private func receive(_ event: Event, from device: IOBluetoothHandsFree?) {
        guard let device else { return }
        let source = ObjectIdentifier(device)
        Task { @MainActor [weak self] in
            guard let self, let current = self.handsFree, ObjectIdentifier(current) == source else { return }
            self.handle(event, on: current)
        }
    }

    private func handle(_ event: Event, on device: IOBluetoothHandsFreeDevice) {
        switch event {
        case .connected(let status):
            timeout?.cancel(); timeout = nil
            connecting = false
            guard status == 0 else {
                disconnect()
                error = String(localized: "Could not connect calls. Pair your phone in Bluetooth settings and try again.")
                return
            }
            connected = true
            error = nil
            UserDefaults.standard.set(selectedID, forKey: "callPhone")
            UserDefaults.standard.set(true, forKey: "bluetoothCallsEnabled")
            active = device.indicator(IOBluetoothHandsFreeIndicatorCall) != 0
            incoming = device.indicator(IOBluetoothHandsFreeIndicatorCallSetup) == 1
        case .disconnected:
            disconnect()
            error = String(localized: "Bluetooth calls disconnected. Connect again when your phone is nearby.")
        case .callActive(let value):
            active = value
            if active {
                incoming = false
                if wantsMacAudio { openAudio() }
            } else {
                wantsMacAudio = false
                audioTimeout?.cancel(); audioTimeout = nil
                device.disconnectSCO()
                audioConnected = false
                if !incoming { caller = "" }
            }
        case .setup(let mode):
            if mode == 1 && !incoming { wantsMacAudio = false }
            incoming = mode == 1
            // Setup can clear before the call-active indicator arrives after Answer. Preserve
            // the user's audio request until that event instead of losing it in this gap.
            if !incoming && !active { caller = "" }
        case .incoming(let number):
            if !incoming { wantsMacAudio = false }
            caller = number
            incoming = true
        case .audioOpened(let status):
            audioTimeout?.cancel(); audioTimeout = nil
            // A late SCO callback must not override a switch back to phone audio.
            guard wantsMacAudio, active else {
                audioConnected = false
                device.transferAudioToPhone()
                return
            }
            if status == 0 { audioConnected = true; error = nil }
            else { audioFailed() }
        case .audioClosed:
            audioConnected = false
        }
    }

    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        receive(.connected(status?.int32Value ?? -1), from: device)
    }
    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        receive(.disconnected, from: device)
    }
    nonisolated func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive value: NSNumber!) {
        receive(.callActive(value?.boolValue == true), from: device)
    }
    nonisolated func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode value: NSNumber!) {
        receive(.setup(value?.intValue ?? 0), from: device)
    }
    nonisolated func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        receive(.incoming(String((number ?? "").prefix(80))), from: device)
    }
    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        receive(.audioOpened(status?.int32Value ?? -1), from: device)
    }
    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        receive(.audioClosed, from: device)
    }

}

struct BluetoothCallSettings: View {
    @ObservedObject private var calls = BluetoothCalls.shared
    @ObservedObject private var state = AppState.shared

    /// A phone with a live session that can bond on its own; older app versions cannot.
    private var pairable: AppState.DeviceState? {
        state.focusedDevice.flatMap { $0.caps.contains("bt_pair") ? $0 : nil }
    }

    /// Sections for a grouped `Form`: Settings → Calls, and the calls page of the welcome window.
    var body: some View {
        // The automatic route first: the phone bonds on its own when it advertises `bt_pair`.
        if let phone = pairable, !calls.connected, !calls.connecting {
            Section {
                LabeledContent {
                    HStack(spacing: Theme.Space.small) {
                        if calls.pairing { ProgressView().controlSize(.small) }
                        Button("Pair") { calls.pair(with: phone.id) }
                            .disabled(calls.pairing)
                    }
                } label: {
                    Text(phone.name)
                    Text("Pairs with this Mac over Bluetooth")
                }
            } footer: {
                if let note = calls.pairNote { Text(note).formNote() }
            }
        }

        Section {
            if calls.phones.isEmpty {
                LabeledContent("Phone", value: String(localized: "None paired over Bluetooth"))
            } else {
                Picker("Phone", selection: $calls.selectedID) {
                    ForEach(calls.phones) { phone in Text(phone.name).tag(phone.id) }
                }
                .disabled(calls.connected || calls.connecting)
            }
            HStack(spacing: Theme.Space.small) {
                Button("Bluetooth settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                }
                Button("Refresh") { calls.refresh() }
                Spacer(minLength: 0)
                if calls.connecting { ProgressView().controlSize(.small) }
                if calls.connected || calls.connecting {
                    Button("Disconnect") { calls.disable() }
                } else if !calls.phones.isEmpty {
                    Button("Connect") { calls.connect() }
                }
            }
            if calls.connected { BluetoothCallControls() }
            if let error = calls.error {
                Text(error)
                    .font(Theme.Font.label)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("If macOS can't open the call audio, the call stays on the phone").formNote()
        }
        // Listing paired devices raises the Bluetooth prompt, so it runs on its own only once
        // that is answered; the Refresh button asks for it.
        .onAppear {
            if calls.phones.isEmpty, SystemPermissions.shared.bluetooth == .allowed { calls.refresh() }
        }
    }
}

struct BluetoothCallControls: View {
    @ObservedObject private var calls = BluetoothCalls.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Label(calls.phoneName, systemImage: "phone.connection")
                .font(Theme.Font.heading)
            if calls.incoming {
                Text(calls.caller.isEmpty ? String(localized: "Incoming call") : calls.caller)
                    .font(Theme.Font.body).textSelection(.enabled)
                HStack {
                    Button("Answer") { calls.answer() }
                    Button("Decline", role: .destructive) { calls.endCall() }
                }
            } else if calls.active {
                HStack {
                    if calls.audioConnected {
                        Button("Use phone audio") { calls.usePhoneAudio() }
                    } else {
                        Button("Use Mac audio") { calls.useMacAudio() }
                    }
                    Button("End call", role: .destructive) { calls.endCall() }
                }
            } else {
                Text("Ready for calls").font(Theme.Font.label).foregroundStyle(.secondary)
            }
        }
    }
}
