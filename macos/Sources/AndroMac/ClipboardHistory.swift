import AndroMacKit
import Foundation
import SwiftUI

/// Clipboard history — both directions.
///
/// Privacy: JSON sealed with `Store.historyKey` under Application Support, on this Mac only. It is
/// sent nowhere. Deleted when every device is forgotten, on Reset AndroMac, or when the user
/// clears it.
/// Capped at [limit]; the clipboard usually carries short text, so the history stays small.
@MainActor
final class ClipboardHistory: ObservableObject {

    static let shared = ClipboardHistory()

    enum Direction: String, Codable {
        case sent          // Mac -> phone
        case received      // phone -> Mac

        var symbol: String { self == .sent ? "arrow.up" : "arrow.down" }
        var label: String {
            self == .sent
                ? String(localized: "Sent to phone") : String(localized: "Received from phone")
        }
    }

    struct Entry: Identifiable, Codable, Equatable {
        let id: UUID
        let text: String
        let date: Date
        let direction: Direction

        init(text: String, direction: Direction, date: Date = Date()) {
            self.id = UUID()
            self.text = text
            self.date = date
            self.direction = direction
        }

        /// The single-line rendering used in the list.
        var preview: String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        }
    }

    private let limit = 50
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
            .appendingPathComponent("AndroMac/clipboard.json")
        load()
    }

    func record(_ text: String, direction: Direction) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // If the same text arrives twice in a row, do not store it again; move the newest to the top.
        if entries.first?.text == text { return }
        entries.removeAll { $0.text == text }
        entries.insert(Entry(text: text, direction: direction), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        // Coalesced like the notification history: a copy is up to 64 KiB, and 50 of them were
        // re-encoded and written for every copy in either direction.
        scheduleSave()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    /// Clear, and unpairing: the file is deleted rather than rewritten, which works even before
    /// the key is loaded.
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
