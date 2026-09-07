import AppKit
import SwiftUI

/// Search, long lists and app management were moved here so the menu bar panel stays glanceable.
/// Inside `.menuBarExtraStyle(.window)` text field focus is not reliable.
struct MainWindow: View {

    enum Tab: Hashable, CaseIterable {
        case notifications, clipboard, apps, settings

        var title: LocalizedStringKey {
            switch self {
            case .notifications: return "Notifications"
            case .clipboard: return "Clipboard"
            case .apps: return "Apps"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .notifications: return "bell"
            case .clipboard: return "doc.on.clipboard"
            case .apps: return "square.grid.2x2"
            case .settings: return "gearshape"
            }
        }
    }

    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .notifications

    var body: some View {
        // NO padding around this stack. The window used to inset the whole `TabView` by 12 pt,
        // which left a band of bare window material above and below the content — the "transparent
        // gap". Content now runs to the window edge and each screen owns its own insets, which is
        // also what lets a list scroll under the tab bar instead of stopping short of it.
        VStack(spacing: 0) {
            picker
            Divider()
            content
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 400, idealHeight: 620)
        .onAppear { tab = state.requestedTab }
        .onChange(of: state.requestedTab) { _, requested in tab = requested }
    }

    /// A segmented picker rather than `TabView`'s own tab strip: it puts the four screens on one
    /// line, leaves the content area to the screen itself, and does not draw a second background
    /// behind everything.
    private var picker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
        .labelsHidden()
        .padding(.horizontal, Theme.inset)
        .padding(.vertical, Theme.Space.medium)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .notifications: HistoryList()
        case .clipboard: ClipboardList()
        case .apps: AppsList()
        case .settings: SettingsList()
        }
    }
}

/// One search field, used by all three list screens.
///
/// It was written out three times with three slightly different paddings, which is exactly the kind
/// of drift that makes an app feel unfinished.
struct SearchField: View {

    @Binding var text: String
    let prompt: LocalizedStringKey

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Font.label)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.small)
        .padding(.vertical, Theme.Space.snug)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

/// The bar every list screen puts above its content: search on the left, counts and actions right.
struct ListToolbar<Trailing: View>: View {

    @Binding var query: String
    let prompt: LocalizedStringKey
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.small) {
            SearchField(text: $query, prompt: prompt)
            trailing
        }
        .padding(.horizontal, Theme.inset)
        .padding(.bottom, Theme.Space.medium)
    }
}
