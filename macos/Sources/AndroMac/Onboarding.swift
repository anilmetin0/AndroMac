import AndroMacKit
import AppKit
import SwiftUI

/// The welcome window: what the app is, the macOS grants, pairing, calls. Shown once on the first
/// launch with nothing paired, and again from Settings → General.
///
/// Every page can be passed over. It counts as done the moment it first appears, so finishing,
/// skipping, closing it or quitting with it open all keep it from coming back on its own.
@MainActor
enum OnboardingWindow {

    private static var window: NSWindow?
    private static let delegate = Delegate()

    /// The first launch: once, ever. Settings → General calls `show` directly.
    static func showOnFirstLaunch() {
        guard !Store.shared.onboardingDone else { return }
        Store.shared.onboardingDone = true
        // Someone updating with a phone already paired has set the app up without it.
        guard !Store.shared.isPaired else { return }
        show()
    }

    static func show(at step: OnboardingView.Step = .welcome) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "Welcome to AndroMac")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(step: step) { close() }.environmentObject(AppState.shared)
        )
        self.window = window
        // A menu bar app has no Dock icon; without one a window behind others is hard to find again.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        centre(window)
        window.makeKeyAndOrderFront(nil)
        // In front even if macOS declines to activate an app launched in the background.
        window.orderFrontRegardless()
    }

    /// The exact middle of the main screen. `NSWindow.center()` puts a window a third of the way
    /// down instead, and it ran before the hosted view had given the window its size.
    private static func centre(_ window: NSWindow) {
        // The hosted view adds the title bar's height as a safe area on its first layout, after
        // this runs; size the window for it now, or it grows downwards once it was placed.
        if let view = window.contentViewController?.view {
            let titleBar = window.frame.height - window.contentLayoutRect.height
            let fitting = view.fittingSize
            window.setContentSize(NSSize(width: fitting.width, height: fitting.height + titleBar))
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { window.center(); return }
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                      y: (area.midY - size.height / 2).rounded()))
    }

    static func close() { window?.close() }

    fileprivate static func closed() {
        Store.shared.onboardingDone = true
        window = nil
        if !AppState.appWindowVisible() && !DemoMode.isOn { NSApp.setActivationPolicy(.accessory) }
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { OnboardingWindow.closed() }
        }
    }
}

struct OnboardingView: View {

    enum Step: String, CaseIterable {
        case welcome, permissions, pair, calls, done
    }

    @State var step: Step
    let finish: () -> Void

    @EnvironmentObject private var state: AppState
    @ObservedObject private var calls = BluetoothCalls.shared
    @ObservedObject private var permissions = SystemPermissions.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which way the last page turn went, so Back slides the other way.
    @State private var forward = true

    var body: some View {
        VStack(spacing: 0) {
            page
                .id(step)
                .transition(transition)
                // The welcome page has nothing below its title, so it sits in the middle.
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: step == .welcome ? .center : .top)
            footer
        }
        .frame(width: 560, height: 540)
        .clipped()
    }

    // MARK: pages

    @ViewBuilder
    private var page: some View {
        VStack(spacing: Theme.Space.large) {
            header
            switch step {
            case .welcome: EmptyView()
            case .permissions: form { Section { PermissionList(showsKeychain: false) } }
            case .pair: pair
            case .calls: form { BluetoothCallSettings() }
            case .done: form { summary }
            }
        }
        .padding(.top, step == .welcome ? 0 : 40)
        .padding(.horizontal, Theme.Space.large)
    }

    private var header: some View {
        VStack(spacing: Theme.Space.small) {
            hero.padding(.bottom, Theme.Space.tight)
            Text(title)
                .font(Theme.Font.display)
            Text(subtitle)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private var hero: some View {
        if step == .welcome {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(step == .done ? Color.green : Color.accentColor)
                .frame(height: 44)
                .accessibilityHidden(true)
        }
    }

    private var symbol: String {
        switch step {
        case .welcome: return ""
        case .permissions: return "checkmark.shield"
        case .pair: return "iphone.gen3.radiowaves.left.and.right"
        case .calls: return "phone"
        case .done: return "checkmark.circle.fill"
        }
    }

    private var title: LocalizedStringKey {
        switch step {
        case .welcome: return "Welcome to AndroMac"
        case .permissions: return "Allow access"
        case .pair: return "Connect your phone"
        case .calls: return "Calls on your Mac"
        case .done: return "You're all set"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch step {
        case .welcome: return "Your Android phone's notifications, clipboard, files and calls on your Mac"
        case .permissions: return "Turn on what you plan to use"
        case .pair: return "Pair once and the phone reconnects on its own"
        case .calls: return "Answer calls with the Mac's microphone and speakers"
        case .done: return "AndroMac is in the menu bar"
        }
    }

    /// A grouped form on the window's own background, as in Settings.
    private func form(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .padding(.horizontal, -Theme.Space.small)
    }

    /// The panel's steps until a phone is on the line, then the phone itself.
    @ViewBuilder
    private var pair: some View {
        if let phone = state.devices.first {
            Label {
                Text("\(AppState.displayName(phone.name) ?? phone.name) is connected")
                    .font(Theme.Font.heading)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .padding(Theme.Space.medium)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .padding(.horizontal, Theme.Space.medium)
        } else {
            HStack(alignment: .center, spacing: Theme.Space.large) {
                PairSteps()
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The app has to reach the phone first; the code opens the download page there.
                VStack(spacing: Theme.Space.small) {
                    QRCode(Release.latestURL, maxSize: 104)
                    Text("Scan to get the app")
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.large)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            // The same side margins as the grouped forms on the other pages.
            .padding(.horizontal, Theme.Space.medium)
        }
    }

    /// What is set up and what is left, each one a click away in Settings later.
    private var summary: some View {
        Section {
            LabeledContent("Phone", value: phoneSummary)
            LabeledContent("Calls", value: calls.connected
                           ? String(localized: "Ready") : String(localized: "Not set up"))
            LabeledContent("Permissions", value: String(
                localized: "\(allowedCount) of \(SystemPermissions.Kind.allCases.count) allowed"))
        }
    }

    private var phoneSummary: String {
        if let phone = state.devices.first { return AppState.displayName(phone.name) ?? phone.name }
        if Store.shared.isPaired { return String(localized: "Paired") }
        return String(localized: "Not paired")
    }

    private var allowedCount: Int {
        SystemPermissions.Kind.allCases.filter { permissions.grant($0) == .allowed }.count
    }

    // MARK: footer

    private var footer: some View {
        ZStack {
            dots
            HStack(spacing: Theme.Space.small) {
                if step != .done {
                    Button("Skip") { finish() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer(minLength: 0)
                if step != .welcome {
                    Button("Back") { go(-1) }
                        .secondaryAction()
                }
                Button(step == .done ? "Done" : "Continue") {
                    if step == .done { finish() } else { go(1) }
                }
                .prominentAction()
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(Theme.Space.large)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Circle()
                    .fill(item == step ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(index + 1) of \(Step.allCases.count)"))
    }

    private var index: Int { Step.allCases.firstIndex(of: step) ?? 0 }

    private func go(_ delta: Int) {
        let steps = Step.allCases
        let next = steps[min(max(index + delta, 0), steps.count - 1)]
        forward = delta > 0
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3)) { step = next }
    }

    /// A page turn, or only a cross-fade with Reduce Motion on.
    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }
}
