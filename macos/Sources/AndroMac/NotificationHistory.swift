import Foundation
import SwiftUI

/// The local history of notifications received from the phone.
///
/// Privacy: kept as plain JSON under Application Support, on this Mac only; it is sent nowhere.
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

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
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

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
