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

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroMac", isDirectory: true)
        // Private data (clipboard text, notification bodies): owner-only directory.
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        fileURL = base.appendingPathComponent("history.json")
        load()
    }

    func add(_ entry: Entry) {
        // When the same notification is updated (same key), the new one replaces the old.
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        flush()
    }

    /// Read off the main thread: the history key comes from the Keychain, and the first read of
    /// it can wait on a system prompt. Entries added meanwhile stay on top.
    private func load() {
        let url = fileURL
        Task {
            let decoded: [Entry]? = await Task.detached {
                guard let key = Store.shared.historyKey,
                      let raw = try? Data(contentsOf: url),
                      let data = SealedFile.open(raw, key: key) else { return nil }
                return try? JSONDecoder().decode([Entry].self, from: data)
            }.value
            guard let decoded else { return }
            let fresh = self.entries
            self.entries = fresh + decoded.filter { old in !fresh.contains { $0.id == old.id } }
            if self.entries.count > self.limit { self.entries.removeLast(self.entries.count - self.limit) }
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
    private func save() {
        guard let key = Store.shared.historyKey,
              let plain = try? JSONEncoder().encode(entries),
              let data = SealedFile.seal(plain, key: key) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
