import AppKit
import SwiftUI

// MARK: - Bildirimler

struct HistoryList: View {

    @ObservedObject private var history = NotificationHistory.shared
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [NotificationHistory.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.app.lowercased().contains(q)
                || $0.title.lowercased().contains(q)
                || $0.text.lowercased().contains(q)
        }
    }

    var body: some View {
        // Straight under the toolbar, so it scrolls beneath it like any Mac list.
        List(filtered) { entry in
            HistoryRow(entry: entry)
                .listRowInsets(EdgeInsets(
                    top: Theme.Space.tight, leading: Theme.Space.small,
                    bottom: Theme.Space.tight, trailing: Theme.Space.small
                ))
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .softScrollEdges()
        .emptyState(
            filtered.isEmpty,
            symbol: history.entries.isEmpty ? "bell.slash" : "magnifyingglass",
            message: history.entries.isEmpty
                ? String(localized: "Notifications from your phone appear here.")
                : String(localized: "No notifications match your search.")
        )
        .searchable(text: $query, prompt: "Search app, title or text")
        // A count says something only while a search narrows the list.
        .navigationSubtitle(query.isEmpty ? Text(verbatim: "") : Text("\(filtered.count) / \(history.entries.count)"))
        .toolbar {
            Button("Clear") { confirmClear = true }
                .disabled(history.entries.isEmpty)
        }
        .confirmationDialog("Clear the notification history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { history.clear() }
        }
    }
}

/// Icon, then one text column (app and time, title, text), then the picture as a trailing square
/// level with the column's top. The picture is about as tall as three lines of text, so a row with
/// one is not taller than a row without.
private struct HistoryRow: View {
    let entry: NotificationHistory.Entry

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.small) {
            AppIcon(pkg: entry.pkg, fallback: entry.app, size: 28)
            VStack(alignment: .leading, spacing: Theme.Space.hair) {
                HStack(spacing: Theme.Space.tight) {
                    Text(entry.app).lineLimit(1)
                    Text(verbatim: "·")
                    RelativeTime(date: entry.date).fixedSize()
                }
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                if !entry.title.isEmpty {
                    Text(entry.title).font(Theme.Font.heading)
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(Theme.Font.body)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.image != nil {
                NotificationPicture(entry: entry, size: 48)
            }
        }
        .padding(.vertical, Theme.Space.hair)
        .accessibilityElement(children: .combine)
    }
}
