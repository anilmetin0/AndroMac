import AppKit
import SwiftUI

// MARK: - Apps

struct AppsList: View {

    @ObservedObject private var modes = AppModes.shared
    /// Read so the list follows the phone switcher: the apps shown are the focused phone's.
    @EnvironmentObject private var state: AppState
    /// The window's search field, which belongs to the window rather than to the page.
    let query: String

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
            // A header names the three switches, so the rows under it can carry them bare.
            if !filtered.isEmpty { AppColumns.header }
            List(filtered) { app in
                AppColumns.row(app, modes: modes)
                    .listRowInsets(EdgeInsets(top: Theme.Space.tight, leading: Theme.Space.small,
                                              bottom: Theme.Space.tight, trailing: Theme.Space.small))
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .softScrollEdges()
            .emptyState(
                filtered.isEmpty,
                symbol: "square.grid.2x2",
                message: modes.apps.isEmpty
                    ? String(localized: "Apps appear here after their first notification.")
                    : String(localized: "No apps match your search.")
            )

            if !filtered.isEmpty {
                Text("Title only leaves the content on the phone; Off keeps the whole notification there. Banner and History apply on this Mac.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.inset)
                    .padding(.vertical, Theme.Space.small)
            }
        }
        .navigationSubtitle(query.isEmpty ? Text(verbatim: "") : Text("\(filtered.count) / \(modes.apps.count)"))
    }
}

/// The page's columns: the app, what the phone sends, then this Mac's two switches.
private enum AppColumns {
    static let tier: CGFloat = 120
    static let toggle: CGFloat = 64

    static var header: some View {
        HStack(spacing: Theme.Space.small) {
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            Text("Sent from phone").frame(width: tier, alignment: .leading)
            Text("Banner").frame(width: toggle)
            Text("History").frame(width: toggle)
        }
        .font(Theme.Font.label.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // The list row's own insets plus its inset style's margin, so the titles sit over the cells.
        .padding(.horizontal, Theme.Space.small + Theme.inset + Theme.Space.tight)
        .padding(.top, Theme.Space.small)
        .padding(.bottom, Theme.Space.tight)
    }

    @MainActor
    static func row(_ app: AppModes.App, modes: AppModes) -> some View {
        HStack(spacing: Theme.Space.small) {
            AppCell(app: app).frame(maxWidth: .infinity, alignment: .leading)
            TierPicker(app: app).frame(width: tier, alignment: .leading)
            MacSwitch(app: app, history: false, isOn: modes.showsBanner(app.pkg)).frame(width: toggle)
            MacSwitch(app: app, history: true, isOn: modes.keepsHistory(app.pkg)).frame(width: toggle)
        }
    }
}

/// Icon, name and package; dimmed while the phone sends nothing for it.
private struct AppCell: View {
    let app: AppModes.App

    var body: some View {
        HStack(spacing: Theme.Space.small) {
            AppIcon(pkg: app.pkg, fallback: app.label, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.label).font(Theme.Font.heading).lineLimit(1)
                Text(app.pkg)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, Theme.Space.hair)
        .opacity(app.mode == .off ? 0.55 : 1)
    }
}

/// What the phone sends for this app: the tier is applied on the phone (PROTOCOL §6.6).
private struct TierPicker: View {
    let app: AppModes.App

    var body: some View {
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
        .accessibilityLabel(Text("\(app.label), sent from phone"))
    }
}

/// One of the Mac's switches; off for an app the phone sends nothing for, since nothing arrives.
private struct MacSwitch: View {
    let app: AppModes.App
    /// The History switch; the Banner one otherwise.
    let history: Bool
    let isOn: Bool

    private var label: String { history ? String(localized: "History") : String(localized: "Banner") }

    var body: some View {
        Toggle(label, isOn: Binding(
            get: { isOn },
            set: { on in
                if history { AppModes.shared.setHistory(on, for: app.pkg) }
                else { AppModes.shared.setBanner(on, for: app.pkg) }
            }
        ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(app.mode == .off)
            .accessibilityLabel(Text(verbatim: "\(app.label), \(label)"))
    }
}
