import AndroMacKit
import AppKit
import Foundation

/// The phone's screen in a window on the Mac, with mouse and keyboard control, through scrcpy.
///
/// scrcpy does the hard part (the capture server it pushes to the phone, H.264 or H.265 decoding,
/// input injection, audio) and it does it over adb, Android's own debugging channel. That channel
/// is the reason this needs no extra permission in the AndroMac app on the phone and no consent
/// prompt per session, and it is also the one thing the user has to switch on: Wireless debugging
/// in Developer options, or a USB cable. Pairing with that switch is adb's own TLS pairing, a
/// 6-digit code shown on the phone, done once per Mac.
///
/// This class only finds the right adb device for a connected phone and starts or stops scrcpy.
/// Release builds carry scrcpy and adb inside the bundle (`build.sh`, `scripts/fetch-scrcpy.sh`);
/// a build from source falls back to a Homebrew install.
@MainActor
final class ScreenMirror: ObservableObject {

    static let shared = ScreenMirror()

    enum Phase: Equatable {
        case idle
        case starting
        case running
        /// Neither Wireless debugging nor a cable reaches this phone.
        case needsDebugging
        /// Wireless debugging is on, but this Mac has not been paired with it yet.
        case needsPairing
        /// A cable is in, and the phone is showing "Allow USB debugging?".
        case needsApproval
        /// A build from source without scrcpy on the machine.
        case notInstalled
        case failed(String)

        var busy: Bool { self == .starting }
    }

    @Published private(set) var phases: [String: Phase] = [:]

    private var processes: [String: Process] = [:]
    /// The last start request per phone, so a retry, a successful pairing, or the phone reporting
    /// that Wireless debugging came on can pick up where the user left off.
    private var requests: [String: (host: String?, title: String)] = [:]
    /// The adb server this app started, if it started one. adb daemonizes and outlives both scrcpy
    /// and AndroMac, keeping its USB and mDNS watchers and its link to the phone; one this app
    /// started is stopped when the last mirror ends. A server someone else started is left alone.
    private var ownedServer: URL?

    private init() {
        // scrcpy is a separate process and would outlive the app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ScreenMirror.shared.stopAll()
                ScreenMirror.shared.releaseServer()
            }
        }
    }

    /// Start the adb server if none is running, and remember that it is ours.
    private func ensureServer(_ adb: URL) async {
        let (_, out) = await Self.run(adb, ["start-server"])
        if out.contains("daemon started successfully") { ownedServer = adb }
    }

    /// Stop the adb server this app started once nothing uses it.
    private func releaseServer() {
        guard let adb = ownedServer, processes.isEmpty, !phases.values.contains(.starting) else { return }
        ownedServer = nil
        let process = Process()
        process.executableURL = adb
        process.arguments = ["kill-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func phase(_ deviceID: String) -> Phase { phases[deviceID] ?? .idle }

    // MARK: entry points

    func toggle(deviceID: String, host: String?, title: String) {
        if processes[deviceID] != nil { stop(deviceID) } else { start(deviceID: deviceID, host: host, title: title) }
    }

    func start(deviceID: String, host: String?, title: String) {
        guard !phase(deviceID).busy, processes[deviceID] == nil else { return }
        requests[deviceID] = (host, title)
        guard let tools = Tools.find() else { phases[deviceID] = .notInstalled; return }
        phases[deviceID] = .starting
        Task {
            await ensureServer(tools.adb)
            switch await Self.resolve(host: host, adb: tools.adb) {
            case .success(let serial): launch(deviceID: deviceID, serial: serial, title: title, tools: tools)
            case .failure(let problem):
                phases[deviceID] = problem.phase
                releaseServer()
            }
        }
    }

    func retry(_ deviceID: String) {
        guard let request = requests[deviceID] else { return }
        phases[deviceID] = .idle
        start(deviceID: deviceID, host: request.host, title: request.title)
    }

    func dismiss(_ deviceID: String) {
        if processes[deviceID] == nil { phases[deviceID] = nil }
    }

    func stop(_ deviceID: String) {
        processes[deviceID]?.terminate()
    }

    func stopAll() {
        processes.values.forEach { $0.terminate() }
    }

    /// The code from the phone's "Pair device with pairing code" dialog. The dialog advertises its
    /// own port over mDNS, so the code is the only thing the user has to carry across.
    func pair(deviceID: String, code: String) {
        guard let request = requests[deviceID], let host = request.host,
              let tools = Tools.find() else { return }
        let code = code.filter(\.isNumber)
        guard code.count == 6 else { return }
        phases[deviceID] = .starting
        Task {
            await ensureServer(tools.adb)
            // The pairing service can take a moment to show up after the dialog opens.
            var service: String?
            for attempt in 0..<3 where service == nil {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                service = await Self.services(adb: tools.adb)
                    .first { $0.type == "_adb-tls-pairing._tcp" && $0.host == host }?.address
            }
            guard let service else { phases[deviceID] = .needsPairing; return }
            let (_, out) = await Self.run(tools.adb, ["pair", service, code])
            guard out.contains("Successfully paired") else {
                phases[deviceID] = .failed(String(localized: "The code did not match. Open a new code on the phone and try again."))
                return
            }
            // adb connects to a freshly paired phone on its own; give it a moment to do so.
            try? await Task.sleep(for: .seconds(1))
            phases[deviceID] = .idle
            start(deviceID: deviceID, host: host, title: request.title)
        }
    }

    /// The phone reports its Wireless debugging switch (`system.wireless_debugging`). Turning it on
    /// while the Mac is waiting for exactly that continues the start without another click.
    func phoneReported(deviceID: String, wirelessDebugging: Bool) {
        guard wirelessDebugging, phase(deviceID) == .needsDebugging else { return }
        retry(deviceID)
    }

    // MARK: scrcpy

    private func launch(deviceID: String, serial: String, title: String, tools: Tools) {
        let store = Store.shared
        var args = ["--serial=\(serial)", "--window-title=\(title)"]
        if !store.mirrorAudio { args.append("--no-audio") }
        if store.mirrorScreenOff { args.append("--turn-screen-off") }
        if store.mirrorStayAwake { args.append("--stay-awake") }
        if store.mirrorMaxSize > 0 { args.append("--max-size=\(store.mirrorMaxSize)") }
        // AndroMac already carries the clipboard; two syncs of the same text would echo.
        if store.syncClipboard { args.append("--no-clipboard-autosync") }

        let process = Process()
        process.executableURL = tools.scrcpy
        process.arguments = args
        process.environment = tools.environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        // Only the last error line is kept, to say why a start failed. scrcpy logs no content.
        let lastError = LastLine()
        output.fileHandleForReading.readabilityHandler = { handle in
            lastError.feed(handle.availableData)
        }
        process.terminationHandler = { process in
            output.fileHandleForReading.readabilityHandler = nil
            let status = process.terminationStatus
            let reason = process.terminationReason
            Task { @MainActor in
                ScreenMirror.shared.finished(deviceID, status: status, reason: reason, error: lastError.value)
            }
        }
        do {
            try process.run()
            processes[deviceID] = process
            phases[deviceID] = .running
        } catch {
            phases[deviceID] = .failed(error.localizedDescription)
        }
    }

    /// 0 is the window being closed, 2 the phone going away mid-session; neither is worth a message.
    private func finished(_ deviceID: String, status: Int32, reason: Process.TerminationReason, error: String?) {
        processes[deviceID] = nil
        defer { releaseServer() }
        if status == 0 || status == 2 || reason == .uncaughtSignal {
            phases[deviceID] = nil
        } else {
            phases[deviceID] = .failed(error ?? String(localized: "Screen mirroring stopped unexpectedly."))
        }
    }

    // MARK: finding the phone in adb

    enum Problem: Error {
        case debugging, pairing, approval

        var phase: Phase {
            switch self {
            case .debugging: return .needsDebugging
            case .pairing: return .needsPairing
            case .approval: return .needsApproval
            }
        }
    }

    /// Which adb serial is this phone. AndroMac knows the phone by the address its session came
    /// from, so every route is matched against that address; a cable is matched by asking the
    /// phone for its own address. With no address to go on, a single device is taken as it.
    /// The adb server is already running (`ensureServer`).
    nonisolated static func resolve(host: String?, adb: URL) async -> Result<String, Problem> {
        var devices = AdbOutput.devices(await run(adb, ["devices"]).out)
        let services = await self.services(adb: adb)

        if let host {
            if let serial = AdbOutput.ready(devices, at: host, services: services) { return .success(serial) }

            // `_adb._tcp` is a phone left in `adb tcpip` mode that announces itself; it still asks
            // the user to allow this Mac on first contact.
            if let connect = services.first(where: {
                ["_adb-tls-connect._tcp", "_adb._tcp"].contains($0.type) && $0.host == host
            }) {
                let (_, out) = await run(adb, ["connect", connect.address])
                if out.contains("connected to") { return .success(connect.address) }
                return .failure(.pairing)
            }
            if services.contains(where: { $0.type == "_adb-tls-pairing._tcp" && $0.host == host }) {
                return .failure(.pairing)
            }
            // `adb tcpip 5555`, the pre-Android 11 way, survives until the phone reboots.
            let (_, out) = await run(adb, ["connect", "\(host):5555"], timeout: .seconds(3))
            if out.contains("connected to") {
                devices = AdbOutput.devices(await run(adb, ["devices"]).out)
                if let serial = AdbOutput.ready(devices, at: host, services: services) { return .success(serial) }
            }
        }

        let cabled = devices.filter { $0.state == "device" }
        if let host {
            for device in cabled {
                let (_, out) = await run(adb, ["-s", device.serial, "shell", "ip", "-4", "-o", "addr"])
                if out.contains("inet \(host)/") { return .success(device.serial) }
            }
        }
        // Only when the phone's address is unknown. With a known address that matched nothing,
        // the one device adb does have is some other phone, and mirroring it under this phone's
        // name would hand the user control of the wrong device.
        if host == nil, cabled.count == 1 { return .success(cabled[0].serial) }
        if devices.contains(where: { $0.state == "unauthorized" }) { return .failure(.approval) }
        return .failure(.debugging)
    }

    nonisolated static func services(adb: URL) async -> [AdbOutput.Service] {
        AdbOutput.services(await run(adb, ["mdns", "services"]).out)
    }

    /// Runs an adb command and returns its combined output. A command that hangs, which `connect`
    /// to a silent address can, is killed after `timeout`.
    ///
    /// The output goes to a temporary file rather than a pipe: any adb command may fork the adb
    /// server, which inherits the descriptor and lives on, and a pipe read would then wait for
    /// the daemon forever. A file is simply read once the command itself has exited.
    nonisolated static func run(_ tool: URL, _ args: [String], timeout: Duration = .seconds(15)) async -> (status: Int32, out: String) {
        await Task.detached {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("andromac-adb-\(UUID().uuidString).txt")
            guard FileManager.default.createFile(atPath: file.path, contents: nil),
                  let output = try? FileHandle(forWritingTo: file) else { return (-1, "") }
            defer {
                try? output.close()
                try? FileManager.default.removeItem(at: file)
            }
            let process = Process()
            process.executableURL = tool
            process.arguments = args
            process.environment = Tools.baseEnvironment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let kill = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds, execute: kill)
            process.waitUntilExit()
            kill.cancel()
            let data = (try? Data(contentsOf: file)) ?? Data()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    // MARK: tools

    struct Tools {
        let scrcpy: URL
        let adb: URL
        /// Set for the bundled copy; a Homebrew scrcpy knows where its own server and icon are.
        let server: URL?
        var icon: URL?

        var environment: [String: String] {
            var env = Tools.baseEnvironment
            env["ADB"] = adb.path
            if let server { env["SCRCPY_SERVER_PATH"] = server.path }
            if let icon { env["SCRCPY_ICON_PATH"] = icon.path }
            return env
        }

        /// A menu bar app starts with launchd's PATH, which has no Homebrew in it.
        nonisolated static var baseEnvironment: [String: String] {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            return env
        }

        /// scrcpy from the bundle first, then Homebrew. adb is the one already on the machine
        /// when there is one (Homebrew, the Android SDK), the bundled copy otherwise: two adb
        /// clients of different versions each kill the other's server on port 5037, which would
        /// drop Android Studio's devices, or this mirror when Studio takes its server back.
        static func find() -> Tools? {
            let files = FileManager.default
            let home = files.homeDirectoryForCurrentUser.path
            let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] ?? "\(home)/Library/Android/sdk"
            let first = { (paths: [String]) in
                paths.first { files.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            }
            let systemAdb = first(["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "\(sdk)/platform-tools/adb"])
            if let scrcpy = Bundle.main.url(forAuxiliaryExecutable: "scrcpy"),
               let bundledAdb = Bundle.main.url(forAuxiliaryExecutable: "adb"),
               let server = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) {
                return Tools(scrcpy: scrcpy, adb: systemAdb ?? bundledAdb, server: server,
                             icon: Bundle.main.url(forResource: "scrcpy", withExtension: "png"))
            }
            guard let scrcpy = first(["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]),
                  let adb = systemAdb
            else { return nil }
            return Tools(scrcpy: scrcpy, adb: adb, server: nil)
        }
    }
}

/// The last `ERROR:` line scrcpy printed, fed from the pipe's reader thread.
private final class LastLine: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var last: String?

    var value: String? { lock.withLock { last } }

    func feed(_ data: Data) {
        lock.withLock {
            buffer += String(decoding: data, as: UTF8.self)
            let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
            buffer = String(lines.last ?? "")
            for line in lines.dropLast() where line.hasPrefix("ERROR:") {
                last = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
            }
        }
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
