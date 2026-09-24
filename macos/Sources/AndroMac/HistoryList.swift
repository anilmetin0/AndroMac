import AppKit
import SwiftUI

// MARK: - Bildirimler

struct HistoryList: View {

    @ObservedObject private var history = NotificationHistory.shared
    @State private var query = ""

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
        Group {
            if filtered.isEmpty {
                EmptyState(
                    symbol: history.entries.isEmpty ? "bell.slash" : "magnifyingglass",
                    message: history.entries.isEmpty
                        ? String(localized: "Notifications from your phone appear here.")
                        : String(localized: "No notifications match your search.")
                )
            } else {
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
            }
        }
        .searchable(text: $query, prompt: "Search app, title or text")
        .navigationSubtitle(Text("\(filtered.count) / \(history.entries.count)"))
        .toolbar {
            Button("Clear") { history.clear() }
                .disabled(history.entries.isEmpty)
        }
    }
}

private struct HistoryRow: View {
    let entry: NotificationHistory.Entry

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.small) {
            AppIcon(pkg: entry.pkg, fallback: entry.app, size: 28)
            VStack(alignment: .leading, spacing: Theme.Space.hair) {
                HStack(spacing: Theme.Space.tight) {
                    Text(entry.app)
                        .font(Theme.Font.label.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                if !entry.title.isEmpty {
                    Text(entry.title).font(Theme.Font.heading)
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if entry.image != nil {
                NotificationPicture(entry: entry, size: 60)
            }
        }
    }
}
