import AppKit
import SwiftUI

/// Search, long lists, app management and the settings, so the menu bar panel stays glanceable.
/// Inside `.menuBarExtraStyle(.window)` text field focus is not reliable.
///
/// One system sidebar for everything: the three lists, then the settings sections. On macOS 26
/// `NavigationSplitView` gives the sidebar its Liquid Glass look by itself; nothing here restyles it.
struct MainWindow: View {

    enum Tab: Hashable {
        case notifications, clipboard, apps
        case setting(SettingsSection)

        /// "Open Settings" from the panel, the status menu and ⌘,.
        static let settings = Tab.setting(.general)
        static let lists: [Tab] = [.notifications, .clipboard, .apps]

        var title: LocalizedStringKey {
            switch self {
            case .notifications: return "Notifications"
            case .clipboard: return "Clipboard"
            case .apps: return "Apps"
            case .setting(let section): return section.title
            }
        }

        var symbol: String {
            switch self {
            case .notifications: return "bell"
            case .clipboard: return "doc.on.clipboard"
            case .apps: return "square.grid.2x2"
            case .setting(let section): return section.symbol
            }
        }
    }

    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .notifications

    var body: some View {
        NavigationSplitView {
            List(selection: $tab) {
                Section {
                    ForEach(Tab.lists, id: \.self) { row($0) }
                }
                Section("Settings") {
                    ForEach(SettingsSection.allCases) { row(.setting($0)) }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            content
                .id(tab)
                .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.15), value: tab)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 400, idealHeight: 560)
        .onAppear { tab = state.requestedTab }
        .onChange(of: state.requestedTab) { _, requested in tab = requested }
        // Written back so the next request for the same page still counts as a change.
        .onChange(of: tab) { _, current in state.requestedTab = current }
    }

    private func row(_ tab: Tab) -> some View {
        Label(tab.title, systemImage: tab.symbol).tag(tab)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .notifications: HistoryList()
        case .clipboard: ClipboardList()
        case .apps: AppsList()
        case .setting(let section): SettingsList(section: section)
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
        HStack(spacing: Theme.Space.tight) {
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
        .padding(.vertical, Theme.Space.tight + Theme.Space.hair)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
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
        .padding(.vertical, Theme.Space.small)
    }
}
