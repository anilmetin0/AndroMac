import AppKit
import Foundation

/// Keeps the icons of the phone's apps on disk.
///
/// An icon is requested ONCE PER PACKAGE FOR ITS LIFETIME (`icon_request`), and read from disk
/// after that. Embedding it in every notification would mean ~10 KB of extra radio per
/// notification (PROTOCOL §6).
///
/// Observable because an icon usually lands a moment AFTER the first notification of a package
/// was drawn: without a change signal that row kept its letter placeholder.
@MainActor
final class IconCache: ObservableObject {

    static let shared = IconCache()

    private let directory: URL
    /// Packages asked for this session, and which phone was asked. An `app_icon` is only taken
    /// from that phone: with two phones, neither may learn the other's apps or repaint its icons.
    private var requested: [String: String] = [:]
    /// Packages whose file is known to be absent, so a list redraw does not stat the disk each time.
    private var missing = Set<String>()
    /// Decoded icons. SwiftUI evaluates the body often, and decoding the PNG every time was
    /// visibly expensive in lists.
    private var images: [String: NSImage] = [:]

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroMac/icons", isDirectory: true)
        directory = base
        // Application Support ignores HOME: a demo run reads the real icons but writes nothing.
        guard !DemoMode.isOn else { return }
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    private func url(for pkg: String) -> URL {
        // Package names are safe for the file system (letters, digits, dots, underscores), but we
        // still strip the separator characters so that escaping the path is impossible.
        let safe = pkg.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return directory.appendingPathComponent(safe + ".png")
    }

    func cachedURL(for pkg: String) -> URL? {
        if missing.contains(pkg) { return nil }
        let candidate = url(for: pkg)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            missing.insert(pkg)
            return nil
        }
        return candidate
    }

    /// The icon used by the panel and the lists; served from memory after the first read.
    func image(for pkg: String) -> NSImage? {
        if let cached = images[pkg] { return cached }
        guard let url = cachedURL(for: pkg), let image = NSImage(contentsOf: url) else { return nil }
        images[pkg] = image
        return image
    }

    /// Ask the phone that posted the notification for the icon, once per session.
    func requestIfMissing(_ pkg: String, from peer: String) {
        guard cachedURL(for: pkg) == nil, requested[pkg] == nil else { return }
        requested[pkg] = peer
        Task { await Server.shared.send(["t": "icon_request", "pkg": pkg], to: peer) }
    }

    /// An icon arrived. Only the phone that was asked for this package may supply it.
    func store(pkg: String, base64PNG: String, from peer: String) {
        guard requested[pkg] == peer else { return }
        guard let data = Data(base64Encoded: base64PNG), data.count < 512 * 1024 else { return }
        // PNG signature: do not let fabricated data be written to disk.
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            NSLog("AndroMac: the icon received for %@ is not a PNG, skipped", pkg)
            return
        }
        if !DemoMode.isOn { try? data.write(to: url(for: pkg), options: .atomic) }
        missing.remove(pkg)
        images[pkg] = NSImage(data: data)      // make the new icon appear immediately
        objectWillChange.send()
        // The panel and the history list observe the history, not this cache, so they are told
        // too. ponytail: drop this once `AppIcon` observes IconCache.shared itself.
        NotificationHistory.shared.objectWillChange.send()
    }

    /// A session ended: a request that phone never answered may be asked again next session
    /// (PROTOCOL §5 `icon_request`), instead of never until the app restarts.
    func forgetRequests(from peer: String) {
        requested = requested.filter { $0.value != peer }
    }

    /// Unpairing: the icons belong to the phone that sent them, and the next phone must not
    /// inherit them.
    func clear() {
        images.removeAll()
        requested.removeAll()
        missing.removeAll()
        guard !DemoMode.isOn else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "png" { try? FileManager.default.removeItem(at: file) }
    }
}
