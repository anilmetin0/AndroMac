import AndroMacKit
import Foundation
import SwiftUI

/// The local history of notifications received from the phone.
///
/// Privacy: kept under Application Support, on this Mac only, sealed with a key derived from the
/// Keychain identity (`SealedFile`); it is sent nowhere.
/// Capped at [limit]; the user can clear it with a single click.
/// The history is deleted when the pairing is removed.
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
    }

    private let limit = 200
    private let fileURL: URL

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
        load()
    }

    func contains(id: String, title: String, text: String) -> Bool {
        entries.contains { $0.id == id && $0.title == title && $0.text == text }
    }

    func add(_ entry: Entry) {
        // When the same notification is updated (same key), the new one replaces the old.
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        scheduleSave()
    }

    /// Unpairing: the file is deleted rather than rewritten, which works even before the key is loaded.
    func clear() {
        entries.removeAll()
        saveTask?.cancel(); saveTask = nil
        loadTask?.cancel(); loadTask = nil
        loaded = true
        guard !DemoMode.isOn else { return }
        try? FileManager.default.removeItem(at: fileURL)
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
