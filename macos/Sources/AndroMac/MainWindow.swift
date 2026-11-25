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

        var tint: Color {
            switch self {
            case .messages: return .green
            case .notifications, .setting(.notifications): return .red
            case .clipboard, .setting(.clipboard): return .blue
            case .apps: return .indigo
            case .setting(.devices): return .teal
            case .setting(.files): return .cyan
            case .setting(.calls): return .green
            case .setting(.mirroring): return .purple
            case .setting(.permissions): return .orange
            case .setting(.updates): return .pink
            case .setting: return .gray
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
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: Self.sidebarMax)
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
            .modifier(PageSettings(state: state))
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
        // With a page's settings open the window may not get narrower than its three columns:
        // at the old 760 the split view clipped the sidebar and the inspector, and pushed the
        // sidebar off the leading edge and back while it laid out.
        .frame(minWidth: settingsOpen ? Self.widthWithSettings : Self.minWidth, idealWidth: 900,
               minHeight: MainWindow.minHeight, idealHeight: 640)
    }

    /// The page's width as last laid out, read when the window starts to grow or shrink.
    @MainActor static var listWidth: CGFloat = 0
    /// The settings column with the hairline before it.
    static let columnWidth = inspectorWidth + 1

    /// Opens or closes a page's settings the way Xcode's inspector does: the window grows by the
    /// column's width and the column is uncovered as it grows, while the list holds its width.
    /// The system inspector could not do this: inside the old width it slid the whole content,
    /// sidebar included, and snapped it back; with the window growing at the same time the list
    /// went wider and back; growing it in one step looked like the window jumped.
    @MainActor static func toggleSettings(_ state: AppState, animate: Bool) {
        // One at a time: a second click mid-animation read the old state and resized twice.
        guard state.frozenListWidth == nil else { return }
        let opening = !state.pageSettingsShown
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(AndroMacApp.mainWindowID) == true })
        else { state.pageSettingsShown = opening; return }
        var frame = window.frame
        frame.size.width = max(frame.width + (opening ? columnWidth : -columnWidth), minWidth)
        if let screen = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, screen.width)
            frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            state.frozenListWidth = listWidth
            if opening { state.pageSettingsShown = true }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animate ? 0.25 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) {
                    if !opening { state.pageSettingsShown = false }
                    state.frozenListWidth = nil
                }
            }
        })
    }

    /// Not while the window is growing or shrinking around the settings: the minimum would stop it.
    private var settingsOpen: Bool {
        state.pageSettingsShown && state.requestedTab.settings != nil && state.frozenListWidth == nil
    }

    /// The sidebar, then Messages' conversation list and a conversation that still reads.
    static let minWidth: CGFloat = 760

    static let sidebarMax: CGFloat = 240
    /// A page's settings beside its list: the inspector's ideal width, and what the list keeps.
    static let inspectorWidth: CGFloat = 280
    static let listMinWidth: CGFloat = 420
    static let widthWithSettings = sidebarMax + listMinWidth + inspectorWidth

    /// The whole sidebar fits at the default sidebar icon size, so it never needs to scroll; a
    /// sidebar that scrolls moves its rows under the title bar when a click scrolls one into view.
    /// The minimum also overrides a shorter frame the window may have saved before.
    // Known limit: sized for the medium sidebar icon size; on "Large" the sidebar can still scroll.
    static let minHeight: CGFloat = 536

    private var nothingToClear: Bool {
        state.requestedTab == .clipboard ? clipboard.entries.isEmpty : notifications.entries.isEmpty
    }

    private func row(_ tab: Tab) -> some View {
        // Tinted tiles as System Settings has, the same colours as the menu bar panel's sections.
        Label {
            Text(tab.title)
        } icon: {
            Image(systemName: tab.symbol)
                .symbolVariant(.fill)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tab.tint.gradient, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .tag(tab)
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

/// A page's own settings in a column beside it, opened from the toolbar: the switches sit next
/// to the list they change rather than on a second page of the same name.
///
/// One inspector for the window, whatever the page. It used to be attached per page, inside the
/// view that is rebuilt on every selection: going from one list with settings to the other tore
/// down one inspector while the next was put up, and AppKit threw on the toolbar item they both
/// add ("NSToolbar already contains an item"), which ended the app.
private struct PageSettings: ViewModifier {
    @ObservedObject var state: AppState

    private var tab: MainWindow.Tab { state.requestedTab }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func toggleSettings() { MainWindow.toggleSettings(state, animate: !reduceMotion) }

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
                .frame(width: state.frozenListWidth)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { MainWindow.listWidth = geometry.size.width }
                            .onChange(of: geometry.size.width) { MainWindow.listWidth = geometry.size.width }
                    }
                }
            if state.pageSettingsShown, let section = tab.settings {
                HStack(spacing: 0) {
                    Divider()
                    SettingsList(section: section)
                        .id(section)
                        .frame(width: MainWindow.inspectorWidth)
                }
                // Uncovered from the leading edge while the window grows; its full width otherwise.
                .frame(minWidth: state.frozenListWidth == nil ? MainWindow.columnWidth : 0,
                       maxWidth: MainWindow.columnWidth, alignment: .leading)
                .clipped()
            }
        }
            .toolbar {
                if tab.settings != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: toggleSettings) {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        .help("Settings")
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    }
                }
            }
    }
}
