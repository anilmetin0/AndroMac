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

    /// The sidebar selection is `state.requestedTab` itself, one source of truth instead of a copy
    /// kept in sync both ways, and no animation wrapped around the whole split view.
    var body: some View {
        NavigationSplitView {
            List(selection: $state.requestedTab) {
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
                .id(state.requestedTab)
                // The page's name in the system toolbar, where a Mac app puts it.
                .navigationTitle(Text(state.requestedTab.title))
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: MainWindow.minHeight, idealHeight: 640)
    }

    /// The whole sidebar fits at the default sidebar icon size, so it never needs to scroll; a
    /// sidebar that scrolls moves its rows under the title bar when a click scrolls one into view.
    /// The minimum also overrides a shorter frame the window may have saved before.
    // ponytail: sized for the medium sidebar icon size; on "Large" the sidebar can still scroll.
    static let minHeight: CGFloat = 540

    private func row(_ tab: Tab) -> some View {
        Label(tab.title, systemImage: tab.symbol).tag(tab)
    }

    @ViewBuilder
    private var content: some View {
        switch state.requestedTab {
        case .notifications: HistoryList()
        case .clipboard: ClipboardList()
        case .apps: AppsList()
        case .setting(let section): SettingsList(section: section)
        }
    }
}
