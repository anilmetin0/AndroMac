import AndroMacKit
import AppKit
import Combine
import CryptoKit
import Foundation
import Security

/// Downloads a release and puts it in place of the running app.
///
/// AndroMac is not in the App Store, so "there is a new version" has to be followed by something
/// the user can press, or by nothing at all when automatic install is on. Fetch the DMG the
/// release publishes, check it against the release's own `SHA256SUMS.txt`, copy the app out of
/// it, and swap the bundle. A copy installed with Homebrew is upgraded with `brew` instead when
/// the release is a new stable version (`usesHomebrew`).
///
/// What it will not do:
///  - install anything whose checksum is absent from `SHA256SUMS.txt` or does not match it;
///  - install a bundle whose identifier is not `dev.andromac`, or whose version is not the one the
///    release claimed — a redirect that ends somewhere else stops here;
///  - touch anything outside the app bundle and its own temporary directory.
///
/// The swap itself runs in a small shell script after this process exits: a running app cannot
/// reliably replace its own bundle from inside itself, and the script is the same thing every
/// updater on this platform ends up doing.
@MainActor
final class Updater: ObservableObject {

    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        /// Whole percent of the DMG received; 0 until the size is known.
        case downloading(Int)
        case verifying
        case installing
        case failed(String)

        var busy: Bool {
            switch self {
            case .idle, .failed: return false
            case .downloading, .verifying, .installing: return true
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    /// A downloaded, verified app waiting for its swap, and the release it came from.
    @Published private var prepared: (label: String, app: URL, staging: URL)?

    /// The release a verified download is waiting for its swap, so Settings can offer Install now.
    var readyLabel: String? { prepared?.label }
    /// The release the automatic install is waiting to put in place while the Mac is busy.
    private var waiting: Release?
    /// While `waiting`: the events that end a busy spell, so the install does not have to wait
    /// for the next panel open. No timer.
    private var watchers: [AnyCancellable] = []

    private init() {
        // A prepared copy nobody installed is not left in the temporary directory.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let staging = Updater.shared.prepared?.staging { try? FileManager.default.removeItem(at: staging) }
            }
        }
    }

    // MARK: which way

    /// The Homebrew binary, when this copy was installed as the `andromac` cask: the bundle is
    /// `/Applications/AndroMac.app` and the Caskroom has an entry for it.
    nonisolated static let homebrew: URL? = {
        guard Bundle.main.bundleURL.path == "/Applications/AndroMac.app" else { return nil }
        let fm = FileManager.default
        return ["/opt/homebrew", "/usr/local"].first {
            fm.fileExists(atPath: "\($0)/Caskroom/andromac") && fm.isExecutableFile(atPath: "\($0)/bin/brew")
        }.map { URL(fileURLWithPath: "\($0)/bin/brew") }
    }()

    /// Homebrew only sees stable releases with a new version: a new build of the same version,
    /// or a beta, keeps the cask's version and is swapped in by the app itself, which the cask
    /// allows with `auto_updates true`.
    nonisolated static func usesHomebrew(_ release: Release) -> Bool {
        homebrew != nil && !release.prerelease && release.version > UpdateCheck.current
    }

    /// Something this app can put in place: through Homebrew, or a DMG with its checksum file.
    nonisolated static func canInstall(_ release: Release) -> Bool {
        usesHomebrew(release) || (release.macImage != nil && release.checksums != nil)
    }

    // MARK: install

    /// A release the user asked to install while an automatic download was still running: it
    /// goes in as soon as that download is ready, without waiting for the Mac to be idle.
    private var requested: Release?

    /// Install `release` now, then relaunch: the button the user pressed. Returns when the app is
    /// about to quit or when something went wrong (the reason is in `phase`).
    func install(_ release: Release) async {
        guard !DemoMode.isOn else { return }
        if phase.busy {
            if phase != .installing { requested = release }
            return
        }
        requested = nil
        waiting = nil
        watchers = []
        if Self.usesHomebrew(release) { return upgradeWithHomebrew(release) }
        guard !refusesLocation(release), await prepare(release) else { return }
        swapAndQuit(release)
    }

    /// Whether the automatic install is going to put `release` in place, so no window has to ask:
    /// it is on, the release is installable from here, and the last attempt at it did not fail.
    static func installsItself(_ release: Release) -> Bool {
        Store.shared.updateAutoInstall && canInstall(release) && !triedBefore(release)
            && (usesHomebrew(release) || locationProblem == nil)
    }

    /// The automatic install: download and verify now, in the background, and swap once nothing
    /// is running that a restart would cut short (`isIdle`).
    ///
    /// Called while another download runs (the Beta switch moved mid-download), the newest call
    /// wins: that download looks at `waiting` when it ends and starts this one.
    func installWhenIdle(_ release: Release) {
        guard !DemoMode.isOn, Self.installsItself(release) else { return }
        waiting = release
        if phase.busy { return }
        if Self.usesHomebrew(release) || prepared?.label == release.label {
            installIfWaiting()
            return
        }
        Task {
            let ready = await prepare(release)
            let asked = requested
            requested = nil
            if let asked {
                // The user pressed Install now meanwhile: that wins over waiting for idle.
                waiting = nil
                watchers = []
                if asked.label == release.label { if ready { swapAndQuit(release) } }
                else { await install(asked) }
                return
            }
            // Cancelled meanwhile, or another release asked for while this one downloaded.
            guard let next = waiting else { return }
            if next.label != release.label { return installWhenIdle(next) }
            guard ready else { waiting = nil; return }
            installIfWaiting()
        }
    }

    /// The waiting install, if the Mac is idle now; otherwise it watches for that moment.
    /// Called once the download is ready and whenever a busy spell or an open window ends.
    func installIfWaiting() {
        guard let release = waiting, !phase.busy else { return }
        // What the user chose since the download started wins: automatic install off, this
        // release skipped, or the stable channel picked again under a prepared beta.
        guard Store.shared.updateAutoInstall, release.label != Store.shared.updateSkipped,
              !release.prerelease || Store.shared.updateBeta else { return cancelWaiting() }
        let brew = Self.usesHomebrew(release)
        guard brew || prepared?.label == release.label else { return }
        guard Self.isIdle else { watchBusyState(); return }
        waiting = nil
        watchers = []
        if brew { upgradeWithHomebrew(release) } else { swapAndQuit(release) }
    }

    /// Drops the waiting automatic install and the copy it prepared. Called when automatic
    /// install is turned off, the channel changes, or the release is skipped. A download still
    /// running finds nothing waiting when it ends and installs nothing.
    func cancelWaiting() {
        waiting = nil
        watchers = []
        guard !phase.busy, let prepared else { return }
        try? FileManager.default.removeItem(at: prepared.staging)
        self.prepared = nil
    }

    /// Nothing a restart would cut short: no file transfer, no screen mirroring, no pairing prompt,
    /// and no AndroMac window in front of the user, the menu bar panel included. Only the status
    /// item's own window, which is on screen for as long as the icon is in the menu bar, does not
    /// count.
    private static var isIdle: Bool {
        !NSApp.windows.contains { $0.isVisible && !String(describing: type(of: $0)).contains("StatusBarWindow") }
            && FileTransfer.shared.progress == nil
            && !ScreenMirror.shared.phases.values.contains { $0 == .running || $0 == .starting }
            && AppState.shared.pairing == nil
    }

    private func watchBusyState() {
        guard watchers.isEmpty else { return }
        // `@Published` emits before the value is stored; one runloop turn later it is.
        let retry: (Any) -> Void = { _ in MainActor.assumeIsolated { Updater.shared.installIfWaiting() } }
        watchers = [
            FileTransfer.shared.$progress.dropFirst().receive(on: RunLoop.main).sink(receiveValue: retry),
            ScreenMirror.shared.$phases.dropFirst().receive(on: RunLoop.main).sink(receiveValue: retry),
            AppState.shared.$pairing.dropFirst().receive(on: RunLoop.main).sink(receiveValue: retry),
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
                .receive(on: RunLoop.main).sink(receiveValue: retry),
            // The menu bar panel is ordered out rather than closed; the app losing focus is what
            // its closing looks like from here.
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
                .receive(on: RunLoop.main).sink(receiveValue: retry),
        ]
    }

    /// Download, verify, unpack and validate; `prepared` holds the result. False on failure, the
    /// reason in `phase`.
    private func prepare(_ release: Release) async -> Bool {
        if prepared?.label == release.label { return true }
        if let old = prepared { try? FileManager.default.removeItem(at: old.staging); prepared = nil }
        guard let image = release.macImage, let sums = release.checksums else {
            phase = .failed(String(localized: "This release has no macOS build to install."))
            return false
        }
        var staging: URL?
        // Whatever happens the temporary copies go, except on the path that keeps them for the
        // installer script, which clears them itself once the new app is in place.
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        do {
            phase = .downloading(0)
            let archive = try await download(image)
            staging = archive.deletingLastPathComponent()

            phase = .verifying
            let expected = try await checksum(named: image.name, from: sums)
            let app = try await Self.verifyAndUnpack(archive, sha256: expected, release: release)
            prepared = (release.label, app, staging!)
            staging = nil
            phase = .idle
            return true
        } catch {
            phase = .failed((error as? UpdateError)?.text ?? error.localizedDescription)
            return false
        }
    }

    /// The disk and process half of `prepare`, off the main actor: hashing the image, `hdiutil`
    /// and `ditto` take seconds, and the menu bar would hang for all of them.
    @concurrent
    private nonisolated static func verifyAndUnpack(_ archive: URL, sha256 expected: String,
                                                    release: Release) async throws -> URL {
        guard try sha256(of: archive) == expected else {
            throw UpdateError.message(String(localized: "The download does not match the checksum published with the release."))
        }
        return try validate(try unpack(archive), expecting: release)
    }

    // MARK: where it runs

    /// Why this copy cannot replace itself where it is, or nil when it can. A copy run from the
    /// disk image, from another volume, from a translocated path, or from a folder the user
    /// cannot write to would fail in the installer script after the app has already quit.
    nonisolated static var locationProblem: String? {
        let bundle = Bundle.main.bundleURL
        let path = bundle.path
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
                || !FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
        else { return nil }
        return String(localized: "AndroMac can't update itself in this folder. Move it to Applications and try again.")
    }

    /// True, with the reason in `phase` and the update window back up, when this copy cannot
    /// replace itself where it is.
    private func refusesLocation(_ release: Release) -> Bool {
        guard let problem = Self.locationProblem else { return false }
        phase = .failed(problem)
        UpdateWindow.show(release)
        return true
    }

    // MARK: install loop guard

    /// This build, as `announceIfUpdated` names it.
    private static func attempt(_ label: String) -> String { label + "\n" + UpdateCheck.runningBuild }

    /// The last install quit for this release, and this is still the build that quit: it did
    /// not take (the swap failed, or Homebrew had nothing newer yet). Trying it again at every
    /// launch would be a restart loop, so the window asks instead.
    static func triedBefore(_ release: Release) -> Bool {
        Store.shared.updateAttempt == attempt(release.label)
    }

    private func swapAndQuit(_ release: Release) {
        guard let prepared, prepared.label == release.label, !refusesLocation(release) else { return }
        phase = .installing
        do {
            try Self.swap(into: Bundle.main.bundleURL, from: prepared.app, staging: prepared.staging)
            self.prepared = nil                 // the installer script owns these files now
            Store.shared.updateAttempt = Self.attempt(release.label)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// `brew upgrade` once this process is gone, then start the app again. Homebrew downloads
    /// the cask's DMG itself; its cask asks the app to quit first, and it already has.
    /// The output goes to ~/Library/Logs/AndroMac-update.log.
    private func upgradeWithHomebrew(_ release: Release) {
        guard let brew = Self.homebrew else { return }
        phase = .installing
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AndroMac-update.log").path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Every value is an argument; the script interpolates nothing. The app is started again
        // whether or not the upgrade worked, so a failed one does not leave the user without it.
        task.arguments = [
            "-c",
            "exec >>\"$4\" 2>&1; while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; "
                + "\"$2\" update --quiet; \"$2\" upgrade --cask --greedy andromac; open \"$3\"",
            "andromac-brew-update",
            String(ProcessInfo.processInfo.processIdentifier), brew.path, Bundle.main.bundlePath, log,
        ]
        do {
            try task.run()
            Store.shared.updateAttempt = Self.attempt(release.label)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: steps

    private enum UpdateError: Error {
        case message(String)
        var text: String { if case .message(let t) = self { return t }; return "" }
    }

    /// The asset, into a fresh temporary directory of our own.
    ///
    /// `download(from:)` streams to disk rather than holding the archive in memory, and it is the
    /// one API here that does not iterate byte by byte — a 20 MB zip through `URLSession.bytes`
    /// means twenty million awaits, which is slower than the download itself.
    private func download(_ asset: Release.Asset) async throws -> URL {
        let progress = DownloadProgress { percent in
            Task { @MainActor in
                // A late report must not pull the phase back from verifying.
                if case .downloading = Updater.shared.phase { Updater.shared.phase = .downloading(percent) }
            }
        }
        let (temporary, response) = try await URLSession.shared.download(from: asset.url, delegate: progress)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError.message(String(localized: "The download could not be started."))
        }
        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard Int64(size) <= Self.maxDownload else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError.message(String(localized: "The download is larger than expected."))
        }
        let directory = try Self.scratchDirectory()
        let file = directory.appendingPathComponent(asset.name)
        do {
            try FileManager.default.moveItem(at: temporary, to: file)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return file
    }

    /// The hash for `name` in the release's `SHA256SUMS.txt` (`Release.checksum`).
    private func checksum(named name: String, from asset: Release.Asset) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: asset.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 64 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            throw UpdateError.message(String(localized: "The release's checksum file could not be read."))
        }
        guard let hash = Release.checksum(for: name, in: text) else {
            throw UpdateError.message(String(localized: "The release publishes no checksum for this download."))
        }
        return hash
    }

    /// Mount the image read-only at a private mount point, copy the app out with `ditto` (the one
    /// copier that keeps a bundle's symlinks and extended attributes), and unmount again.
    private nonisolated static func unpack(_ image: URL) throws -> URL {
        let base = image.deletingLastPathComponent()
        let mount = base.appendingPathComponent("mount")
        let destination = base.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify",
                                            "-mountpoint", mount.path, image.path]) else {
            throw UpdateError.message(String(localized: "The download could not be opened."))
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let app = mount.appendingPathComponent("AndroMac.app")
        guard run("/usr/bin/ditto", [app.path, destination.appendingPathComponent("AndroMac.app").path]) else {
            throw UpdateError.message(String(localized: "The download does not contain AndroMac."))
        }
        return destination
    }

    /// Runs a system tool to completion; true when it exited 0.
    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// The unpacked directory must contain exactly the app we expect, and nothing is installed
    /// until it does: identifier, name, version and build are all checked against the release,
    /// and the signature against this copy's own (`checkSignature`).
    private nonisolated static func validate(_ directory: URL, expecting release: Release) throws -> URL {
        let app = directory.appendingPathComponent("AndroMac.app")
        guard FileManager.default.fileExists(atPath: app.path),
              let bundle = Bundle(url: app),
              let expected = Bundle.main.bundleIdentifier,
              bundle.bundleIdentifier == expected else {
            throw UpdateError.message(String(localized: "The download does not contain AndroMac."))
        }
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard release.matches(shortVersion: short, bundleVersion: build) else {
            throw UpdateError.message(String(localized: "The download is not the version the release announced."))
        }
        try checkSignature(of: app)
        return app
    }

    /// A copy signed with a real identity only accepts a bundle that meets its own designated
    /// requirement, so a release signed by anyone else is refused even with a matching checksum.
    private nonisolated static func checkSignature(of app: URL) throws {
        guard let requirement = ownRequirement else { return }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw UpdateError.message(String(localized: "The download is not signed like this copy of AndroMac."))
        }
    }

    /// This copy's designated requirement, or nil when it is unsigned or signed ad hoc: an ad-hoc
    /// requirement is its own cdhash, which no other build can meet. Read, and logged, once.
    private nonisolated(unsafe) static let ownRequirement: SecRequirement? = {
        var me: SecCode?
        var mine: SecStaticCode?
        var info: CFDictionary?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopySigningInformation(mine, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue == 0,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement
        else {
            NSLog("AndroMac: this copy is unsigned or signed ad hoc; updates are checked by checksum only")
            return nil
        }
        var text: CFString?
        if SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
           (text as String?)?.hasPrefix("cdhash") == true {
            NSLog("AndroMac: this copy's requirement is a cdhash; updates are checked by checksum only")
            return nil
        }
        return requirement
    }()

    /// Replace `current` with `new` once this process is gone, then start it again.
    ///
    /// The old bundle is moved aside rather than deleted, and only removed after the new one is in
    /// place — if the copy fails, the script puts the old app back and starts that instead, so a
    /// failed update cannot leave the user without an app.
    private nonisolated static func swap(into current: URL, from new: URL, staging: URL?) throws {
        // Every path is passed as an argument and quoted; the script interpolates nothing.
        let script = """
        #!/bin/sh
        current="$1"
        new="$2"
        backup="$3"
        staging="$4"
        pid="$5"
        scratch="$6"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        if mv "$current" "$backup" && ditto "$new" "$current"; then
            /bin/rm -r -f "$backup"
        elif [ -d "$backup" ]; then
            mv "$backup" "$current"
        fi
        /bin/rm -r -f "$staging"
        open "$current"
        /bin/rm -r -f "$scratch"
        """
        // The script sits in its own directory, not in the one it clears.
        let directory = try scratchDirectory()
        let file = directory.appendingPathComponent("install.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        let backup = directory.appendingPathComponent("AndroMac.app.previous")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            file.path, current.path, new.path, backup.path,
            staging?.path ?? directory.path,
            String(ProcessInfo.processInfo.processIdentifier),
            directory.path,
        ]
        try task.run()
    }

    private nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroMacUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 500 MB: two orders of magnitude above the real archive, and still a bound.
    private nonisolated static let maxDownload: Int64 = 500 * 1024 * 1024
}

/// The download's whole percent, once per change. The task's own `Progress` follows the
/// Content-Length of the final response, redirects included; the async `download` calls no
/// per-chunk delegate method, so this watches that instead.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int) -> Void
    // Set once in didCreateTask; the observation fires on the session's serial delegate queue.
    private var observation: NSKeyValueObservation?
    private var last = -1

    init(_ report: @escaping @Sendable (Int) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let percent = min(100, max(0, Int(progress.fractionCompleted * 100)))
            guard let self, percent != last else { return }
            last = percent
            report(percent)
        }
    }
}
