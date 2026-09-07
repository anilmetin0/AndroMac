import AndroMacKit
import AppKit
import CryptoKit
import Foundation

/// Downloads a release and puts it in place of the running app.
///
/// AndroMac is not in the App Store and not on a Homebrew tap everyone has, so "there is a new
/// version" has to be followed by something the user can press. This is that button: fetch the DMG
/// the release publishes, check it against the release's own `SHA256SUMS.txt`, copy the app out
/// of it, and swap the bundle.
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
        case downloading
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

    /// Download, verify and install `release`, then relaunch. Returns when the app is about to quit
    /// or when something went wrong (the reason is in `phase`).
    func install(_ release: Release) async {
        guard !phase.busy else { return }
        guard let image = release.macImage, let sums = release.checksums else {
            phase = .failed(String(localized: "This release has no macOS build to install."))
            return
        }
        var staging: URL?
        // Whatever happens the temporary copies go — except on the path that hands them to the
        // installer script, which clears them itself once the new app is in place.
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        do {
            phase = .downloading
            let archive = try await download(image)
            staging = archive.deletingLastPathComponent()

            phase = .verifying
            let expected = try await checksum(named: image.name, from: sums)
            let actual = try Self.sha256(of: archive)
            guard actual == expected else {
                throw UpdateError.message(String(localized: "The download does not match the checksum published with the release."))
            }

            phase = .installing
            let unpacked = try unpack(archive)
            let app = try validate(unpacked, expecting: release)
            try Self.swap(into: Bundle.main.bundleURL, from: app, staging: staging)
            staging = nil                       // the installer script owns these files now
            NSApp.terminate(nil)
        } catch {
            phase = .failed((error as? UpdateError)?.text ?? error.localizedDescription)
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
        let (temporary, response) = try await URLSession.shared.download(from: asset.url)
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
        try FileManager.default.moveItem(at: temporary, to: file)
        return file
    }

    /// The line for `name` in the release's `SHA256SUMS.txt`, in `sha256  filename` form.
    private func checksum(named name: String, from asset: Release.Asset) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: asset.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 64 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            throw UpdateError.message(String(localized: "The release's checksum file could not be read."))
        }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts.last.map(String.init)?.hasSuffix(name) == true else { continue }
            return String(parts[0]).lowercased()
        }
        throw UpdateError.message(String(localized: "The release publishes no checksum for this download."))
    }

    /// Mount the image read-only at a private mount point, copy the app out with `ditto` (the one
    /// copier that keeps a bundle's symlinks and extended attributes), and unmount again.
    private func unpack(_ image: URL) throws -> URL {
        let base = image.deletingLastPathComponent()
        let mount = base.appendingPathComponent("mount")
        let destination = base.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify",
                                            "-mountpoint", mount.path, image.path]) else {
            throw UpdateError.message(String(localized: "The download could not be opened."))
        }
        defer { _ = Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let app = mount.appendingPathComponent("AndroMac.app")
        guard Self.run("/usr/bin/ditto", [app.path, destination.appendingPathComponent("AndroMac.app").path]) else {
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
    /// until it does: identifier, name and version are all checked against the release.
    private func validate(_ directory: URL, expecting release: Release) throws -> URL {
        let app = directory.appendingPathComponent("AndroMac.app")
        guard FileManager.default.fileExists(atPath: app.path),
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "dev.andromac" else {
            throw UpdateError.message(String(localized: "The download does not contain AndroMac."))
        }
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard AppVersion.find(in: short) == release.version else {
            throw UpdateError.message(String(localized: "The download is not the version the release announced."))
        }
        return app
    }

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
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        if mv "$current" "$backup" && ditto "$new" "$current"; then
            /bin/rm -r -f "$backup"
        elif [ -d "$backup" ]; then
            mv "$backup" "$current"
        fi
        /bin/rm -r -f "$staging"
        open "$current"
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
