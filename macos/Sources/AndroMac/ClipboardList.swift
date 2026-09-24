import AppKit
import SwiftUI

// MARK: - Clipboard

struct ClipboardList: View {

    @ObservedObject private var history = ClipboardHistory.shared
    @State private var query = ""
    @State private var autoSend = Store.shared.clipboardAutoSend
    @State private var copied: UUID?
    @State private var confirmClear = false

    private var filtered: [ClipboardHistory.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if filtered.isEmpty {
                EmptyState(
                    symbol: "doc.on.clipboard",
                    message: history.entries.isEmpty
                        ? String(localized: "Text you copy on either device appears here.")
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
                    .listRowInsets(EdgeInsets(top: Theme.Space.tight, leading: Theme.Space.small,
                                              bottom: Theme.Space.tight, trailing: Theme.Space.small))
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
                .padding(.vertical, Theme.Space.small)
        }
        .searchable(text: $query, prompt: "Search clipboard history")
        .navigationSubtitle(query.isEmpty ? Text(verbatim: "") : Text("\(filtered.count) / \(history.entries.count)"))
        .toolbar {
            Button("Clear") { confirmClear = true }
                .disabled(history.entries.isEmpty)
        }
        .confirmationDialog("Clear the clipboard history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { history.clear() }
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardHistory.Entry
    let justCopied: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Theme.Space.small) {
                Image(systemName: entry.direction.symbol)
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .padding(.top, Theme.Space.hair)
                    .help(entry.direction.label)
                    .accessibilityLabel(entry.direction.label)

                VStack(alignment: .leading, spacing: Theme.Space.hair) {
                    Text(entry.preview)
                        .font(Theme.Font.body)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    RelativeTime(date: entry.date)
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: Theme.Space.small)

                // The one moment of feedback: a brief confirmation on click, then it fades away.
                Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(Theme.Font.label)
                    .foregroundStyle(justCopied ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                    .animation(.easeOut(duration: 0.18), value: justCopied)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy to the Mac clipboard")
    }
}
