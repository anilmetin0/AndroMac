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
        VStack(spacing: 0) {
            ListToolbar(query: $query, prompt: "Search app, title or text") {
                Text("\(filtered.count) / \(history.entries.count)")
                    .font(Theme.Font.label.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Clear") { history.clear() }
                    .disabled(history.entries.isEmpty)
                    .secondaryAction()
                    .controlSize(.small)
            }

            if filtered.isEmpty {
                EmptyState(
                    symbol: history.entries.isEmpty ? "bell.slash" : "magnifyingglass",
                    message: history.entries.isEmpty
                        ? String(localized: "No notifications yet.")
                        : String(localized: "No notifications match your search.")
                )
            } else {
                // Edge to edge and scrolling under the bar above, rather than boxed in by a divider.
                List(filtered) { entry in
                    HistoryRow(entry: entry)
                        .listRowInsets(EdgeInsets(
                            top: Theme.Space.snug, leading: Theme.Space.medium,
                            bottom: Theme.Space.snug, trailing: Theme.Space.medium
                        ))
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .softScrollEdges()
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: NotificationHistory.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(pkg: entry.pkg, fallback: entry.app, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
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
        }
        .padding(.vertical, 2)
    }
}
