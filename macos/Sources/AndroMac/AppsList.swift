import AppKit
import SwiftUI

// MARK: - Uygulamalar

struct AppsList: View {

    @ObservedObject private var modes = AppModes.shared
    @State private var query = ""

    private var filtered: [AppModes.App] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return modes.apps }
        return modes.apps.filter {
            $0.label.lowercased().contains(q) || $0.pkg.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(query: $query, prompt: "Search apps") {
                Text("\(modes.apps.count) apps")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }

            if filtered.isEmpty {
                EmptyState(
                    symbol: "square.grid.2x2",
                    message: modes.apps.isEmpty
                        ? String(localized: "Apps are listed here once the phone connects and a notification arrives.")
                        : String(localized: "No apps match your search.")
                )
            } else {
                List(filtered) { app in
                    AppRow(app: app)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .softScrollEdges()

                Text("Applied on the phone. Title only sends the title and leaves the content behind.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Theme.inset)
                    .padding(.vertical, Theme.Space.small)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AppRow: View {
    let app: AppModes.App

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(pkg: app.pkg, fallback: app.label, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.label).font(Theme.Font.heading)
                Text(app.pkg)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { app.mode },
                set: { AppModes.shared.set($0, for: app.pkg) }
            )) {
                ForEach(AppModes.Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
        }
        .opacity(app.mode == .off ? 0.55 : 1)
    }
}
