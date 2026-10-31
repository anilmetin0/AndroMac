import AppKit
import SwiftUI

/// Search, long lists, app management and the settings, so the menu bar panel stays glanceable.
/// Inside `.menuBarExtraStyle(.window)` text field focus is not reliable.
///
/// One system sidebar for everything: Messages, the three lists, then the settings sections. On
/// macOS 26 `NavigationSplitView` gives the sidebar its Liquid Glass look by itself; nothing here
/// restyles it.
struct MainWindow: View {

    enum Tab: Hashable {
        case messages, notifications, clipboard, apps
        case setting(SettingsSection)

        /// "Open Settings" from the panel, the status menu and ⌘,.
        static let settings = Tab.setting(.general)
        static let pages: [Tab] = [.messages, .notifications, .clipboard, .apps]

        /// The settings shown beside the page, in an inspector, instead of a page of their own.
        var settings: SettingsSection? {
            switch self {
            case .notifications: return .notifications
            case .clipboard: return .clipboard
            default: return nil
            }
        }

        /// A settings section that lives beside its list opens that list.
        var page: Tab {
            switch self {
            case .setting(.notifications): return .notifications
            case .setting(.clipboard): return .clipboard
            default: return self
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .messages: return "Messages"
            case .notifications: return "Notifications"
            case .clipboard: return "Clipboard"
            case .apps: return "Apps"
            case .setting(let section): return section.title
            }
        }

        var symbol: String {
            switch self {
            case .messages: return "message"
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
                // What came from the phone, each page with its own settings beside it, then the
                // settings that belong to no list.
                Section {
                    ForEach(Tab.pages, id: \.self) { row($0) }
                }
                Section("Settings") {
                    ForEach(SettingsSection.sidebar) { row(.setting($0)) }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            if state.requestedTab == .messages {
                // Names its own title: the open conversation, with the number or phone under it.
                MessagesView()
            } else {
                content
                    .id(state.requestedTab)
                    // The page's name in the system toolbar, where a Mac app puts it.
                    .navigationTitle(Text(state.requestedTab.title))
                    .modifier(PageSettings(tab: state.requestedTab, shown: $state.pageSettingsShown))
            }
        }
        .frame(minWidth: MainWindow.minWidth, idealWidth: 900, minHeight: MainWindow.minHeight, idealHeight: 640)
    }

    /// The sidebar, then Messages' conversation list and a conversation that still reads; also
    /// a list with its settings open beside it.
    static let minWidth: CGFloat = 760

    /// The whole sidebar fits at the default sidebar icon size, so it never needs to scroll; a
    /// sidebar that scrolls moves its rows under the title bar when a click scrolls one into view.
    /// The minimum also overrides a shorter frame the window may have saved before.
    // ponytail: sized for the medium sidebar icon size; on "Large" the sidebar can still scroll.
    static let minHeight: CGFloat = 536

    private func row(_ tab: Tab) -> some View {
        Label(tab.title, systemImage: tab.symbol).tag(tab)
    }

    @ViewBuilder
    private var content: some View {
        switch state.requestedTab {
        case .messages: MessagesView()
        case .notifications: HistoryList()
        case .clipboard: ClipboardList()
        case .apps: AppsList()
        case .setting(let section): SettingsList(section: section)
        }
    }
}

/// A page's own settings in the system inspector, opened from the toolbar: the switches sit next
/// to the list they change rather than on a second page of the same name.
private struct PageSettings: ViewModifier {
    let tab: MainWindow.Tab
    @Binding var shown: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let section = tab.settings {
            content
                .inspector(isPresented: $shown) {
                    SettingsList(section: section)
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 420)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { shown.toggle() } label: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        .help("Settings")
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    }
                }
        } else {
            content
        }
    }
}
