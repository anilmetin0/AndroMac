import AndroMacKit
import Foundation
import SwiftUI

/// The local history of notifications received from the phone.
///
/// Privacy: kept under Application Support, on this Mac only, sealed with a key derived from the
/// Keychain identity (`SealedFile`); it is sent nowhere.
/// Capped at [limit]; the user can clear it with a single click.
/// The history is deleted when the pairing is removed.
///
/// A notification's picture (PROTOCOL §5 `img`) sits next to it in `images/`: re-encoded without
/// metadata, owner-only (0600 in a 0700 folder), and deleted with its entry when the entry is
/// replaced, pruned past [limit] or cleared. Not sealed, so the views can load it by URL.
@MainActor
final class NotificationHistory: ObservableObject {

    static let shared = NotificationHistory()

    struct Entry: Identifiable, Codable, Equatable {
        let id: String          // StatusBarNotification.key
        let app: String
        let pkg: String
        let title: String
        let text: String
        let date: Date
        /// The picture or avatar file in `images/`, when the phone sent one. Optional, so a
        /// history written before pictures still decodes.
        let image: String?

        init(id: String, app: String, pkg: String, title: String, text: String, date: Date, image: String? = nil) {
            self.id = id; self.app = app; self.pkg = pkg
            self.title = title; self.text = text; self.date = date; self.image = image
        }
    }

    private let limit = 200
    private let fileURL: URL
    private let imagesURL: URL

    @Published private(set) var entries: [Entry] = []
    private var saveTask: Task<Void, Never>?
    /// Nothing is written before the file was read: a save before that would replace the stored
    /// history with only what arrived since launch.
    private var loaded = false
    private var loadTask: Task<Void, Never>?

    private init() {
        // Application Support ignores HOME, so a demo run touches none of this (see `save`).
        fileURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroMac/history.json")
        imagesURL = fileURL.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
        load()
    }

    func contains(id: String, title: String, text: String) -> Bool {
        entries.contains { $0.id == id && $0.title == title && $0.text == text }
    }

    /// The picture of an entry already shown for this notification key, if any.
    func image(forID id: String) -> String? {
        entries.first { $0.id == id }?.image
    }

    /// Where an entry's picture is, or nil when it has none. The file may be gone (cleared).
    func imageURL(for entry: Entry) -> URL? {
        entry.image.flatMap(imageURL(named:))
    }

    func imageURL(named name: String) -> URL? {
        // The name comes from our own sealed file, but a path must never climb out of `images/`.
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return imagesURL.appendingPathComponent(name)
    }

    /// Writes a validated picture and returns its file name, or nil (demo, disk error).
    func saveImage(_ image: NotificationImage.Clean) -> String? {
        guard !DemoMode.isOn else { return nil }
        let name = UUID().uuidString + "." + image.fileExtension
        let fm = FileManager.default
        try? fm.createDirectory(at: imagesURL, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let ok = fm.createFile(
            atPath: imagesURL.appendingPathComponent(name).path, contents: image.data,
            attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]
        )
        return ok ? name : nil
    }

    func add(_ entry: Entry) {
        // When the same notification is updated (same key), the new one replaces the old.
        var dropped = entries.filter { $0.id == entry.id }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > limit {
            dropped += entries.suffix(entries.count - limit)
            entries.removeLast(entries.count - limit)
        }
        deleteImages(Set(dropped.compactMap(\.image)).subtracting([entry.image].compactMap { $0 }))
        scheduleSave()
    }

    private func deleteImages(_ names: Set<String>) {
        guard !DemoMode.isOn else { return }
        for url in names.compactMap(imageURL(named:)) { try? FileManager.default.removeItem(at: url) }
    }

    /// After the load: files no entry points at (an entry dropped by the merge or the cap, a quit
    /// before the history was written) are deleted.
    private func sweepImages() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesURL.path)) ?? []
        deleteImages(Set(files).subtracting(entries.compactMap(\.image)))
    }

    /// Unpairing: the file is deleted rather than rewritten, which works even before the key is loaded.
    func clear() {
        entries.removeAll()
        saveTask?.cancel(); saveTask = nil
        loadTask?.cancel(); loadTask = nil
        loaded = true
        guard !DemoMode.isOn else { return }
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: imagesURL)
    }

    /// Reads the file once the identity key is in memory; until then it does nothing, and
    /// Server.start calls it again after loading the identity off the main thread. The decrypt and
    /// decode run detached. Entries added meanwhile stay on top.
    func load() {
        guard !DemoMode.isOn, !loaded, loadTask == nil, let key = Store.shared.historyKey else { return }
        let url = fileURL
        loadTask = Task {
            let decoded: [Entry]? = await Task.detached {
                guard let raw = try? Data(contentsOf: url),
                      let data = SealedFile.open(raw, key: key) else { return nil }
                return try? JSONDecoder().decode([Entry].self, from: data)
            }.value
            guard !Task.isCancelled else { return }
            loadTask = nil
            loaded = true
            let fresh = entries
            if let decoded {
                entries = fresh + decoded.filter { old in !fresh.contains { $0.id == old.id } }
                if entries.count > limit { entries.removeLast(entries.count - limit) }
            }
            sweepImages()
            if !fresh.isEmpty { scheduleSave() }        // what arrived before the load was not saved
        }
    }

    /// Delays the write by 1 s and coalesces: a flood of notifications used to re-encode the whole
    /// list and write it to disk on every message. [flush] drains it on quit.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Push the pending write to disk immediately (on app quit and when clearing).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    /// Sealed with `Store.historyKey`, so the file is useless to anything without the Keychain.
    /// Never in a demo: its seeded entries would replace the user's real history.
    private func save() {
        guard !DemoMode.isOn, loaded, let key = Store.shared.historyKey,
              let plain = try? JSONEncoder().encode(entries),
              let data = SealedFile.seal(plain, key: key) else { return }
        // Private data (clipboard text, notification bodies): owner-only directory.
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
