import AndroMacKit
import AppKit
import CryptoKit
import Foundation
import Network

/// Advertises itself over Bonjour, waits for the phone to connect, and maintains the single session.
/// docs/PROTOCOL.md §1 and §6.
actor Server {

    static let shared = Server()

    private let queue = DispatchQueue(label: "dev.andromac.net")
    private var listener: NWListener?
    /// Every live session, keyed by the peer's device fingerprint (`PairedDevice.id`).
    ///
    /// The Mac is the listener, so holding several phones at once is natural at the socket level;
    /// what used to make it impossible was everything above it describing exactly one peer. Each
    /// entry owns its own read loop and its own ping timer, so one phone dropping cannot disturb
    /// another, and a reconnect replaces only its own row.
    private var sessions: [String: Session] = [:]
    private var pingTasks: [String: Task<Void, Never>] = [:]
    private var serveTasks: [String: Task<Void, Never>] = [:]
    private var wakeObserver: NSObjectProtocol?

    /// A deliberate `stop()`. This flag distinguishes listener cancellations: if the user stopped
    /// us we do not restart, if the network or the OS cancelled us we do.
    private var stopping = false

    /// The number of connections still handshaking, not yet authenticated. Anyone on the network
    /// can connect; an unbounded number of pending handshakes would be a cheap resource drain.
    private var pendingHandshakes = 0
    private let maxPendingHandshakes = 4
    private let handshakeTimeout: Duration = .seconds(10)

    /// Listener rebuild delay; doubles on every failure, resets on .ready.
    private var restartDelay: Duration = .seconds(3)

    /// The time of the last pairing prompt. A prompt is shown at most once every 30 s so that a
    /// stranger cannot connect repeatedly and flood the user with alerts.
    private var lastPairingPrompt: Date?

    /// Keys the user has rejected in the pairing prompt, with how often and until when they are
    /// muted. Every rejection doubles the mute (1, 2, 4 … 60 min), an approval clears it. The
    /// pairing code is a fresh one-in-a-million guess per attempt, so this is not what keeps a
    /// MITM out; it keeps a stranger from turning the prompt into a nag and caps how many guesses
    /// anyone gets per hour. In memory only: a restart starts over.
    private var rejectedKeys: [Data: (count: Int, until: Date)] = [:]

    /// The low-battery alert fires once per session. Reset when the phone is plugged in or rises
    /// back above 20%.
    /// Phones already warned about in this session. Per device — one phone going flat must not
    /// silence the warning for the other.
    private var lowBatteryAlerted: Set<String> = []

    /// PROTOCOL §6.1 — ONLY the Mac sends the liveness probe; the phone sets up no timer.
    private let pingInterval: Duration = .seconds(240)

    // MARK: lifecycle

    func start() async {
        guard listener == nil else { return }
        stopping = false
        installWakeObserver()
        let store = Store.shared
        _ = store.publicKey                            // triggers identity()

        // If the Keychain was denied, our identity is ephemeral. Going on the air would make the
        // phone see a pin mismatch and raise the CRITICAL "key has changed" alarm — that would
        // desensitise the user to a real MITM warning over a benign local error.
        if store.keychainDenied {
            await MainActor.run {
                AppState.shared.status =
                    .failed(String(localized: "Keychain access denied — restart the app and allow it"))
            }
            return
        }

        var txt = NWTXTRecord()
        txt["v"] = "3"
        txt["n"] = store.deviceName

        let params = NWParameters.tcp
        params.includePeerToPeer = false          // local network only; no AWDL/peer-to-peer
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true

        do {
            let l = try NWListener(using: params, on: .any)
            l.service = NWListener.Service(
                name: store.deviceName, type: "_andromac._tcp", domain: nil, txtRecord: txt
            )
            l.newConnectionHandler = { [weak self] conn in
                Task { await self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { await self?.onListenerState(state) }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            await MainActor.run { AppState.shared.status = .failed(error.localizedDescription) }
        }
    }

    /// `updateUI: false` only while the app is quitting: `applicationWillTerminate` blocks the
    /// main thread on a semaphore, so hopping to the MainActor from here would deadlock.
    func stop(updateUI: Bool = true) async {
        stopping = true
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        for task in pingTasks.values { task.cancel() }
        for task in serveTasks.values { task.cancel() }
        pingTasks.removeAll(); serveTasks.removeAll()
        for session in sessions.values { await session.close() }
        sessions.removeAll()
        listener?.cancel(); listener = nil
        // Both hops are skipped on quit: the main thread is blocked waiting for this call, so a
        // hop to it never returns and every quit used to sit out the full 2 s timeout.
        if updateUI {
            await MainActor.run {
                AppState.shared.devices.removeAll()
                AppState.shared.status = .stopped
            }
        }
    }

    /// After the user decided on a pairing prompt: wait for the phone, it will reconnect on its
    /// own. A rejection mutes that key for a growing while (see `rejectedKeys`).
    func rearm(key: Data, approved: Bool) async {
        if approved {
            rejectedKeys[key] = nil
        } else {
            let count = (rejectedKeys[key]?.count ?? 0) + 1
            let minutes = min(60, 1 << (count - 1))
            rejectedKeys[key] = (count, Date().addingTimeInterval(TimeInterval(minutes * 60)))
            NSLog("AndroMac: pairing rejected, muting that key for %d min", minutes)
        }
        await MainActor.run { AppState.shared.pairing = nil }
    }

    private func onListenerState(_ state: NWListener.State) async {
        switch state {
        case .ready:
            restartDelay = .seconds(3)
            await MainActor.run { AppState.shared.status = .listening }
        case .failed(let e):
            await restartListener(reason: e.localizedDescription)
        case .waiting(let e):
            // With no network NWListener parks itself and returns to .ready ON ITS OWN once the
            // path comes back; rebuilding would be pointless churn. We only surface the state.
            await MainActor.run { AppState.shared.status = .failed(e.localizedDescription) }
        case .cancelled:
            // Sleep, a network change or an OS cancellation also land here; we stay quiet only if
            // the user stopped us, otherwise the listener never returns and the app goes deaf.
            guard !stopping else { break }
            await restartListener(reason: String(localized: "listener was cancelled"))
        default:
            break
        }
    }

    private func restartListener(reason: String) async {
        await MainActor.run { AppState.shared.status = .failed(reason) }
        listener = nil
        let delay = restartDelay
        // On a permanent error (e.g. no local network permission) retrying every 3 s is a pointless wake-up.
        restartDelay = min(delay * 2, .seconds(30))
        try? await Task.sleep(for: delay)
        guard !stopping else { return }      // the user may have stopped us while we waited
        await start()
    }

    /// After waking from sleep the TCP session may already be dead, but the socket does not know
    /// it until the first write. A single `ping` write triggers the RST, the read loop drops and
    /// the connection is re-established.
    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { await Server.shared.pingAfterWake() }
        }
    }

    private func pingAfterWake() async {
        guard !sessions.isEmpty else { return }
        // Every phone, not just one: they all went stale over the same sleep.
        await send(["t": "ping"])
    }

    // MARK: connection

    /// The live session is preserved UNTIL the handshake completes. Previously the current session
    /// was closed as soon as a new connection arrived: anyone on the network could drop the phone
    /// with a single TCP connection. Now only an authenticated peer can take over.
    private func accept(_ conn: NWConnection) async {
        guard case .hostPort(let host, _) = conn.endpoint, Self.isPrivate(host) else {
            // PROTOCOL §3 — local network only. A connection from a routable address does not even
            // enter the handshake; this app is not a service exposed to the internet.
            NSLog("AndroMac: rejected a connection from outside the local network")   // the address is not logged
            conn.cancel()
            return
        }
        guard pendingHandshakes < maxPendingHandshakes else {
            conn.cancel()
            return
        }
        pendingHandshakes += 1
        defer { pendingHandshakes -= 1 }

        do {
            let session = try await handshake(conn)
            let deviceID = PairedDevice.fingerprint(of: session.peerStaticPub)

            // A paused device stays paired but is not let in. Pausing has to bite HERE rather than
            // by closing the socket later: the phone reconnects on its own ladder, so anything that
            // merely drops the link just turns into a retry loop.
            guard Store.shared.device(id: deviceID)?.paused != true else {
                NSLog("AndroMac: a paused phone tried to connect, declining")
                await session.close()
                return
            }

            // Same phone reconnecting: replace its own row and leave every other phone alone.
            // The old read loop is cancelled first so it cannot tear down its successor.
            if sessions[deviceID] != nil {
                serveTasks[deviceID]?.cancel()
                await closeSession(deviceID, updateUI: false)
            }

            sessions[deviceID] = session
            Store.shared.updateDevice(id: deviceID) { $0.lastSeen = Date() }
            serveTasks[deviceID] = Task { await self.serve(session, id: deviceID) }
        } catch let WireError.untrusted(key, name, sas, isFirstDevice) {
            // An untrusted peer does not touch the current session; the user is simply asked.
            NSLog("AndroMac: pairing required, SAS %@", sas)
            await promptPairing(key: key, name: name, sas: sas, isFirstDevice: isFirstDevice)
        } catch {
            NSLog("AndroMac: handshake failed — \(error.localizedDescription)")
        }
    }

    /// RFC 1918 / link-local / ULA / loopback. A peer that gives a name (DNS) is not assumed to be
    /// local: on incoming connections the endpoint is always an IP.
    private static func isPrivate(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a):
            return isPrivateV4([UInt8](a.rawValue))
        case .ipv6(let a):
            if a.isLoopback || a.isLinkLocal { return true }
            let b = [UInt8](a.rawValue)
            guard b.count == 16 else { return false }
            // ::ffff:a.b.c.d — how an IPv4 peer can appear on a dual-stack listener.
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF {
                return isPrivateV4(Array(b[12...]))
            }
            return (b[0] & 0xFE) == 0xFC                  // fc00::/7 (ULA)
        default:
            return false
        }
    }

    private static func isPrivateV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        return b[0] == 10
            || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254)               // link-local (APIPA)
            || b[0] == 127                                // loopback (testing on the same Mac)
    }

    /// Races the handshake against a timeout. Without it a half-finished handshake (a peer that
    /// connects and then goes silent) would hold a slot forever.
    private func handshake(_ conn: NWConnection) async throws -> Session {
        let store = Store.shared
        let queue = self.queue
        let staticKey = store.identity()
        let peerName = store.pairedName.isEmpty ? "Android" : store.pairedName
        // Every trusted phone, not just the first. A paused device is deliberately still in the
        // list: pausing is "do not talk to me", not "forget me", so the handshake still succeeds
        // and `serve` is the one that declines — otherwise a paused phone would be shown to the
        // user as an unknown device asking to pair.
        let pinnedKeys = store.pairedDevices.map(\.key)
        let timeout = handshakeTimeout

        return try await withThrowingTaskGroup(of: Session?.self) { group in
            group.addTask {
                try await Session.accept(
                    connection: conn, queue: queue, staticKey: staticKey,
                    peerName: peerName, pinnedKeys: pinnedKeys
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                // Closing the socket is the only way out: the handshake read does not observe
                // cancellation, it observes an error.
                conn.cancel()
                return nil
            }

            var timedOut = false
            while let result = try await group.next() {
                guard let session = result else { timedOut = true; continue }
                if timedOut { await session.close(); break }
                group.cancelAll()
                return session
            }
            throw WireError.protocolError("handshake timed out")
        }
    }

    private func promptPairing(key: Data, name: String, sas: String, isFirstDevice: Bool) async {
        // The code is per attempt (handshake v2). Once the user confirmed on the phone, it pins and
        // reconnects on its backoff ladder without showing a code; every retry would replace the
        // window with a code the user can never compare. The first attempt's code is the one the
        // phone showed, so a prompt already on screen for the same key is kept.
        if await MainActor.run(body: { AppState.shared.pairing?.peerKey == key }) { return }
        if let muted = rejectedKeys[key], Date() < muted.until { return }
        if let last = lastPairingPrompt, Date().timeIntervalSince(last) < 30 { return }
        lastPairingPrompt = Date()
        await MainActor.run {
            AppState.shared.pairing = .init(
                peerKey: key, peerName: name, sas: sas, isFirstDevice: isFirstDevice
            )
        }
    }

    private func serve(_ session: Session, id deviceID: String) async {
        let store = Store.shared
        let name = store.device(id: deviceID)?.name ?? ""
        await MainActor.run {
            AppState.shared.focusedDeviceID = deviceID
            AppState.shared.update(deviceID: deviceID, name: name) { _ in }
            LinkStats.shared.sessionStarted()
        }

        _ = await send([
            "t": "hello", "name": store.deviceName, "platform": "macos",
            "proto": 3,
            "caps": ["battery", "clipboard", "notification", "find_phone", "media", "file"],
        ], to: deviceID)

        // One timer per phone. PROTOCOL §6.1 still holds: the phone never sets a timer of its own,
        // it only answers, so N phones cost N pings from the Mac and nothing on the battery side.
        pingTasks[deviceID] = Task { [pingInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pingInterval)
                if Task.isCancelled { return }
                _ = await self.send(["t": "ping"], to: deviceID)
            }
        }

        // The pasteboard poller is shared: one watcher feeds every phone that wants the clipboard,
        // so a second device does not mean a second poll.
        await ClipboardWatcher.shared.startWatching()

        while !Task.isCancelled {
            do {
                let (msg, bytes) = try await session.receiveCounted()
                await handle(msg, bytes: bytes, from: deviceID)
            } catch {
                NSLog("AndroMac: session ended — \(error.localizedDescription)")
                break
            }
        }
        // A handed-over session must not close its successor: when `accept` installs a new session
        // for the same phone this loop also ends here, and the row now belongs to someone else.
        if sessions[deviceID] === session { await closeSession(deviceID) }
    }

    /// Drop one phone's session, leaving every other phone connected.
    private func closeSession(_ deviceID: String, updateUI: Bool = true) async {
        pingTasks[deviceID]?.cancel(); pingTasks[deviceID] = nil
        await sessions[deviceID]?.close()
        sessions[deviceID] = nil
        serveTasks[deviceID] = nil
        lowBatteryAlerted.remove(deviceID)

        if updateUI {
            let stillConnected = !sessions.isEmpty
            await MainActor.run {
                AppState.shared.removeDevice(id: deviceID)
                if !stillConnected { AppState.shared.status = .listening }
                LinkStats.shared.sessionEnded()
                FileTransfer.shared.sessionEnded()
            }
        }
        // The poller exists to feed phones; with none left it is just a timer burning cycles.
        if sessions.isEmpty { await ClipboardWatcher.shared.stopWatching() }
    }

    // MARK: incoming messages

    private func handle(_ msg: sending [String: Any], bytes: Int, from deviceID: String) async {
        let type = msg["t"] as? String ?? ""
        // Privacy: only the message type and size are counted, the content is never logged or stored.
        await MainActor.run { LinkStats.shared.recordReceived(type, bytes: bytes) }
        if type != "pong" { NSLog("AndroMac: message received: %@", type) }
        switch type {
        case "ping":
            await send(["t": "pong"])

        case "pong":
            break

        case "hello":
            let name = clip(msg["name"], 64).isEmpty ? "Android" : clip(msg["name"], 64)
            // We show no button in the UI for a capability the peer did not advertise.
            let caps = Set(msg["caps"] as? [String] ?? [])
            Store.shared.pairedName = name
            await MainActor.run {
                AppState.shared.status = .connected(name)
                AppState.shared.peerCaps = caps
            }

        case "battery":
            guard Store.shared.syncBattery, let level = msg["level"] as? Int else { break }
            let b = AppState.Battery(
                level: level,
                charging: msg["charging"] as? Bool ?? false,
                status: msg["status"] as? String ?? "unknown",
                temperature: msg["temp"] as? Double,
                updated: Date()
            )
            let name = Store.shared.device(id: deviceID)?.name ?? ""
            await MainActor.run {
                AppState.shared.update(deviceID: deviceID, name: name) { $0.battery = b }
            }
            await checkLowBattery(b, from: deviceID)

        case "clipboard":
            guard Store.shared.syncClipboard, let text = msg["text"] as? String, !text.isEmpty else { break }
            await ClipboardWatcher.shared.applyFromPhone(text)
            let name = Store.shared.device(id: deviceID)?.name ?? ""
            await MainActor.run {
                AppState.shared.update(deviceID: deviceID, name: name) { $0.lastClipboard = text }
            }

        case "media":
            guard Store.shared.syncMedia else { break }
            // active=false → nothing is playing on the phone any more, the row is removed entirely.
            let mediaName = Store.shared.device(id: deviceID)?.name ?? ""
            guard msg["active"] as? Bool == true else {
                await MainActor.run {
                    AppState.shared.update(deviceID: deviceID, name: mediaName) { $0.media = nil }
                }
                break
            }
            let m = AppState.Media(
                playing: msg["playing"] as? Bool ?? false,
                title: clip(msg["title"]),
                artist: clip(msg["artist"]),
                album: clip(msg["album"]),
                app: clip(msg["app"]),
                pkg: clip(msg["pkg"])
            )
            await MainActor.run {
                AppState.shared.update(deviceID: deviceID, name: mediaName) { $0.media = m }
            }

        case "system":
            // Ringer and volume, sent on connect and whenever they change on the phone (PROTOCOL §5).
            // The values are clamped here: the controls are drawn from them, and a bogus maximum
            // would put the slider somewhere impossible.
            let max = min(Swift.max(msg["volume_max"] as? Int ?? 0, 0), 100)
            let system = AppState.PhoneSystem(
                ringer: ["normal", "vibrate", "silent"].contains(clip(msg["ringer"], 16))
                    ? clip(msg["ringer"], 16) : "normal",
                volume: min(Swift.max(msg["volume"] as? Int ?? 0, 0), max),
                volumeMax: max,
                canSilence: msg["can_silence"] as? Bool ?? false
            )
            let systemName = Store.shared.device(id: deviceID)?.name ?? ""
            await MainActor.run {
                AppState.shared.update(deviceID: deviceID, name: systemName) { $0.system = system }
            }

        case "notification":
            guard Store.shared.syncNotifications else { break }
            await NotificationMirror.shared.show(msg)

        case "app_modes":
            let raw = msg["apps"] as? [[String: Any]] ?? []
            await MainActor.run { AppModes.shared.replace(with: raw) }

        case "app_icon":
            guard let pkg = msg["pkg"] as? String, let png = msg["png"] as? String else { break }
            await MainActor.run { IconCache.shared.store(pkg: pkg, base64PNG: png) }

        case "notification_remove":
            guard let id = msg["id"] as? String else { break }
            await NotificationMirror.shared.remove(id)

        case _ where type.hasPrefix("file_"):
            // PROTOCOL §5 file_* — offer/accept/chunk/ack/done/result/cancel, both directions.
            await FileTransfer.shared.handle(type, msg)

        default:
            break        // unknown type: ignore silently (forward compatibility)
        }
    }

    /// Incoming text fields are untrusted: the type is validated and the value is clipped at 200
    /// characters. The panel shows a single line, so longer text is not worth keeping.
    private func clip(_ value: Any?, _ limit: Int = 200) -> String {
        String((value as? String ?? "").prefix(limit))
    }

    /// If the phone is out of reach, its battery dies silently. One notification is enough: the
    /// flag resets when the phone is plugged in or rises 5 points above the threshold, otherwise
    /// it would repeat on every `battery` message.
    private func checkLowBattery(_ b: AppState.Battery, from deviceID: String) async {
        let threshold = Store.shared.lowBatteryThreshold
        if b.charging || b.level > threshold + 5 { lowBatteryAlerted.remove(deviceID) }
        guard Store.shared.lowBatteryAlert, !lowBatteryAlerted.contains(deviceID),
              !b.charging, b.level <= threshold else { return }
        lowBatteryAlerted.insert(deviceID)
        let name = Store.shared.device(id: deviceID)?.name ?? ""
        await NotificationMirror.shared.showLowBattery(level: b.level, phone: name)
    }

    // MARK: outgoing messages (from other components)

    /// `false` = it did not go out. When the error was swallowed the UI stayed on "Connected" and
    /// the counters inflated; the first write notices the dead socket, so we tear the session down
    /// right there.
    @discardableResult
    /// Send to one phone. Returns false when it is not connected or the write failed.
    func send(_ msg: sending [String: Any], to deviceID: String) async -> Bool {
        guard let json = Self.encode(msg) else { return false }
        return await send(json: json, to: deviceID)
    }

    /// Send to every connected phone. What "sync" means for anything not addressed at one device in
    /// particular. Returns true if at least one phone took it.
    @discardableResult
    func send(_ msg: sending [String: Any]) async -> Bool {
        await deliver(msg, to: Array(sessions.keys))
    }

    /// Send only to the phones the user chose as clipboard targets.
    ///
    /// With two phones, "sync my clipboard" is a different answer for each, so the Mac's clipboard
    /// goes where it was asked to go and nowhere else.
    @discardableResult
    func sendToClipboardTargets(_ msg: sending [String: Any]) async -> Bool {
        let targets = Store.shared.pairedDevices
            .filter(\.receivesClipboard)
            .map(\.id)
            .filter { sessions[$0] != nil }
        return await deliver(msg, to: targets)
    }

    /// Encode once, seal per session. `Session.send(json:)` exists for exactly this.
    private func deliver(_ msg: sending [String: Any], to ids: [String]) async -> Bool {
        guard !ids.isEmpty, let json = Self.encode(msg) else { return false }
        var delivered = false
        for deviceID in ids where await send(json: json, to: deviceID) { delivered = true }
        return delivered
    }

    private func send(json: Data, to deviceID: String) async -> Bool {
        guard let session = sessions[deviceID] else { return false }
        let size: Int
        do {
            size = try await session.send(json: json)
        } catch {
            NSLog("AndroMac: send failed — \(error.localizedDescription)")
            // The first write notices a dead socket, so this phone's session ends right here —
            // and only this phone's.
            if sessions[deviceID] === session {
                serveTasks[deviceID]?.cancel()
                await closeSession(deviceID)
            }
            return false
        }
        await MainActor.run { LinkStats.shared.recordSent(bytes: size) }
        return true
    }

    private static func encode(_ msg: sending [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes])
    }

    /// Hang up on one phone without forgetting it. Pairing survives; the phone will be refused on
    /// its next attempt for as long as it stays paused.
    func disconnect(_ deviceID: String) async {
        serveTasks[deviceID]?.cancel()
        await closeSession(deviceID)
    }

    var isConnected: Bool { !sessions.isEmpty }
}
