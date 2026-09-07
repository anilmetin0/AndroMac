import AppKit
import SwiftUI

// MARK: - Clipboard

struct ClipboardList: View {

    @ObservedObject private var history = ClipboardHistory.shared
    @State private var query = ""
    @State private var autoSend = Store.shared.clipboardAutoSend
    @State private var copied: UUID?

    private var filtered: [ClipboardHistory.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(query: $query, prompt: "Search clipboard history") {
                Button("Clear") { history.clear() }
                    .disabled(history.entries.isEmpty)
                    .secondaryAction()
                    .controlSize(.small)
            }

            if filtered.isEmpty {
                EmptyState(
                    symbol: "doc.on.clipboard",
                    message: history.entries.isEmpty
                        ? String(localized: "Text you copy collects here. Click a row to put it back on the Mac clipboard.")
                        : String(localized: "No entries match your search.")
                )
            } else {
                List(filtered) { entry in
                    ClipboardRow(entry: entry, justCopied: copied == entry.id) {
                        Task {
                            await ClipboardWatcher.shared.restore(entry.text)
                            copied = entry.id
                            try? await Task.sleep(for: .seconds(1.4))
                            if copied == entry.id { copied = nil }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .contextMenu {
                        Button("Copy to clipboard") {
                            Task { await ClipboardWatcher.shared.restore(entry.text) }
                        }
                        Button("Send to phone") {
                            Task { await ClipboardWatcher.shared.sendManually(entry.text) }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { history.remove(entry) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .softScrollEdges()
            }

            Divider()

            // The list runs to the window edge now, so this footer supplies its own inset.
            Toggle("Send to the phone automatically when I copy on the Mac", isOn: $autoSend)
                .onChange(of: autoSend) { _, v in Store.shared.clipboardAutoSend = v }
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(Theme.Font.body)
                .padding(.horizontal, Theme.inset)
                .padding(.vertical, Theme.Space.medium)
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardHistory.Entry
    let justCopied: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.direction.symbol)
                    .font(Theme.Font.section)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)
                    .help(entry.direction.label)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.preview)
                        .font(Theme.Font.body)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 6)

                // The one moment of feedback: a brief confirmation on click, then it fades away.
                Image(systemName: justCopied ? "checkmark.circle.fill" : "arrow.down.doc")
                    .font(Theme.Font.label)
                    .foregroundStyle(justCopied ? Color.green : Color.secondary.opacity(0.5))
                    .animation(.easeOut(duration: 0.18), value: justCopied)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
