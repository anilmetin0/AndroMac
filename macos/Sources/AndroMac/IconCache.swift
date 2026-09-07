import AppKit
import Foundation

/// Keeps the icons of the phone's apps on disk.
///
/// An icon is requested ONCE PER PACKAGE FOR ITS LIFETIME (`icon_request`), and read from disk
/// after that. Embedding it in every notification would mean ~10 KB of extra radio per
/// notification (PROTOCOL §6).
@MainActor
final class IconCache {

    static let shared = IconCache()

    private let directory: URL
    private var requested = Set<String>()
    /// Decoded icons. SwiftUI evaluates the body often, and decoding the PNG every time was
    /// visibly expensive in lists.
    private var images: [String: NSImage] = [:]

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroMac/icons", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        directory = base
    }

    private func url(for pkg: String) -> URL {
        // Package names are safe for the file system (letters, digits, dots, underscores), but we
        // still strip the separator characters so that escaping the path is impossible.
        let safe = pkg.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return directory.appendingPathComponent(safe + ".png")
    }

    func cachedURL(for pkg: String) -> URL? {
        let candidate = url(for: pkg)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// The icon used by the panel and the lists; served from memory after the first read.
    func image(for pkg: String) -> NSImage? {
        if let cached = images[pkg] { return cached }
        guard let url = cachedURL(for: pkg), let image = NSImage(contentsOf: url) else { return nil }
        images[pkg] = image
        return image
    }

    /// Ask the phone for the icon unless it was already requested in this session.
    func requestIfMissing(_ pkg: String) {
        guard cachedURL(for: pkg) == nil, !requested.contains(pkg) else { return }
        requested.insert(pkg)
        Task { await Server.shared.send(["t": "icon_request", "pkg": pkg]) }
    }

    func store(pkg: String, base64PNG: String) {
        guard let data = Data(base64Encoded: base64PNG), data.count < 512 * 1024 else { return }
        // PNG signature: do not let fabricated data be written to disk.
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            NSLog("AndroMac: the icon received for %@ is not a PNG, skipped", pkg)
            return
        }
        try? data.write(to: url(for: pkg), options: .atomic)
        images[pkg] = NSImage(data: data)      // make the new icon appear immediately
    }

    /// Unpairing: the icons belong to the phone that sent them, and the next phone must not
    /// inherit them.
    func clear() {
        images.removeAll()
        requested.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "png" { try? FileManager.default.removeItem(at: file) }
    }

    /// UserNotifications MOVES the attachment file into its OWN store; so we hand it a fresh
    /// temporary copy every time in order not to lose the cached one.
    func temporaryCopy(for pkg: String) -> URL? {
        guard let source = cachedURL(for: pkg) else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("andromac-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
