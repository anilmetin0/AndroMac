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

        /// The prompt of the window's search field on this page; nil for a page without one.
        var searchPrompt: LocalizedStringKey? {
            switch self {
            case .notifications: return "Search app, title or text"
            case .clipboard: return "Search clipboard history"
            case .apps: return "Search apps"
            default: return nil
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
    @ObservedObject private var notifications = NotificationHistory.shared
    @ObservedObject private var clipboard = ClipboardHistory.shared
    @State private var query = ""
    /// The list whose Clear was pressed; the dialog acts on it even if the page changes meanwhile.
    @State private var clearTarget: Tab?

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
            Group {
                if state.requestedTab == .messages {
                    // Names its own title: the open conversation, with the number or phone under it.
                    MessagesView()
                } else {
                    content
                        .id(state.requestedTab)
                        // The page's name in the system toolbar, where a Mac app puts it.
                        .navigationTitle(Text(state.requestedTab.title))
                }
            }
            // Search, Clear and the settings beside a list are the window's, outside the page that
            // is rebuilt on every selection. Declared per page, the next page's search field (or
            // inspector) went into the toolbar while the last one's was still there, and AppKit
            // threw "already contains an item" and ended the app: Notifications to Clipboard.
            .modifier(PageSearch(prompt: state.requestedTab.searchPrompt, text: $query))
            .toolbar {
                if state.requestedTab == .notifications || state.requestedTab == .clipboard {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear") { clearTarget = state.requestedTab }
                            .disabled(nothingToClear)
                    }
                }
            }
            .modifier(PageSettings(tab: state.requestedTab, shown: $state.pageSettingsShown))
            .confirmationDialog(
                clearTarget == .clipboard
                    ? LocalizedStringKey("Clear the clipboard history?")
                    : LocalizedStringKey("Clear the notification history?"),
                isPresented: Binding(get: { clearTarget != nil }, set: { if !$0 { clearTarget = nil } }),
                presenting: clearTarget
            ) { target in
                Button("Clear", role: .destructive) {
                    if target == .clipboard { clipboard.clear() } else { notifications.clear() }
                }
            }
            .onChange(of: state.requestedTab) { query = "" }
        }
        .frame(minWidth: MainWindow.minWidth, idealWidth: 900, minHeight: MainWindow.minHeight, idealHeight: 640)
    }

    /// The sidebar, then Messages' conversation list and a conversation that still reads; also
    /// a list with its settings open beside it.
    static let minWidth: CGFloat = 760

    /// The whole sidebar fits at the default sidebar icon size, so it never needs to scroll; a
    /// sidebar that scrolls moves its rows under the title bar when a click scrolls one into view.
    /// The minimum also overrides a shorter frame the window may have saved before.
    // Known limit: sized for the medium sidebar icon size; on "Large" the sidebar can still scroll.
    static let minHeight: CGFloat = 536

    private var nothingToClear: Bool {
        state.requestedTab == .clipboard ? clipboard.entries.isEmpty : notifications.entries.isEmpty
    }

    private func row(_ tab: Tab) -> some View {
        Label(tab.title, systemImage: tab.symbol).tag(tab)
    }

    @ViewBuilder
    private var content: some View {
        switch state.requestedTab {
        case .messages: MessagesView()
        case .notifications: HistoryList(query: query)
        case .clipboard: ClipboardList(query: query)
        case .apps: AppsList(query: query)
        case .setting(let section): SettingsList(section: section)
        }
    }
}

/// The window's one search field, on the pages that have a list to search. Going from one list to
/// another keeps the same field; only a page without a list takes it away.
private struct PageSearch: ViewModifier {
    let prompt: LocalizedStringKey?
    @Binding var text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if let prompt {
            content.searchable(text: $text, prompt: Text(prompt))
        } else {
            content
        }
    }
}

/// A page's own settings in the system inspector, opened from the toolbar: the switches sit next
/// to the list they change rather than on a second page of the same name.
///
/// One inspector for the window, whatever the page. It used to be attached per page, inside the
/// view that is rebuilt on every selection: going from one list with settings to the other tore
/// down one inspector while the next was put up, and AppKit threw on the toolbar item they both
/// add ("NSToolbar already contains an item"), which ended the app.
private struct PageSettings: ViewModifier {
    let tab: MainWindow.Tab
    @Binding var shown: Bool

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: Binding(
                get: { shown && tab.settings != nil },
                // Only a list with settings may change it: leaving for a page without them must
                // not switch the inspector off for the next list.
                set: { if tab.settings != nil { shown = $0 } }
            )) {
                if let section = tab.settings {
                    SettingsList(section: section)
                        .id(section)
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 420)
                }
            }
            .toolbar {
                if tab.settings != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button { shown.toggle() } label: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        .help("Settings")
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    }
                }
            }
    }
}
