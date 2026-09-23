import AppKit
import SwiftUI

// MARK: - Uygulamalar

struct AppsList: View {

    @ObservedObject private var modes = AppModes.shared
    /// Read so the list follows the tab: the apps shown are the focused phone's.
    @EnvironmentObject private var state: AppState
    @State private var query = ""

    private var filtered: [AppModes.App] {
        _ = state.focusedDeviceID
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return modes.apps }
        return modes.apps.filter {
            $0.label.lowercased().contains(q) || $0.pkg.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if filtered.isEmpty {
                EmptyState(
                    symbol: "square.grid.2x2",
                    message: modes.apps.isEmpty
                        ? String(localized: "Apps appear here after their first notification.")
                        : String(localized: "No apps match your search.")
                )
            } else {
                List(filtered) { app in
                    AppRow(app: app)
                        .listRowInsets(EdgeInsets(top: Theme.Space.tight, leading: Theme.Space.small,
                                              bottom: Theme.Space.tight, trailing: Theme.Space.small))
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .softScrollEdges()

                Text("Title only leaves the content on the phone.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Theme.inset)
                    .padding(.vertical, Theme.Space.small)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .searchable(text: $query, prompt: "Search apps")
        .navigationSubtitle(Text("\(modes.apps.count) apps"))
    }
}

private struct AppRow: View {
    let app: AppModes.App

    var body: some View {
        HStack(spacing: Theme.Space.small) {
            AppIcon(pkg: app.pkg, fallback: app.label, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.label).font(Theme.Font.heading)
                Text(app.pkg)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.small)
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
