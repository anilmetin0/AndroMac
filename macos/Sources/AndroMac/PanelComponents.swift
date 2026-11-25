import AndroMacKit
import AppKit
import SwiftUI

// The small building blocks of the menu bar panel.

extension View {
    /// The menu-item highlight macOS draws under the pointer, bled past the row's edges so the
    /// text column does not move.
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

private struct HoverHighlight: ViewModifier {
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(.primary.opacity(hovered && enabled ? 0.06 : 0))
                    .padding(.horizontal, -Theme.Space.tight - 2)
            }
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A round glass icon button with its tooltip and VoiceOver label, the one shape every panel
/// action takes.
struct IconButton: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.Font.label)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: 16, height: 16)
                .contentTransition(.symbolEffect(.replace))
        }
        .glassIcon()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A labelled action under the phone: a small glass capsule with the symbol and a one-word name,
/// so a row of them reads without hovering. The full description stays in the tooltip and the
/// VoiceOver label.
struct ActionTile: View {
    let symbol: String
    let title: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: symbol).contentTransition(.symbolEffect(.replace))
            }
            .font(Theme.Font.label)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonBorderShape(.capsule)
        .secondaryAction()
        .controlSize(.small)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A round glass button that opens a native menu, dropped down under the button as a pull-down
/// menu is. SwiftUI's `Menu` does not take the glass button style (it drew a flat disc), and glass
/// laid over it swallowed its clicks; this is the same `IconButton` as every other panel action,
/// with an `NSMenu` behind the click.
struct GlassMenuButton: View {
    let symbol: String
    let label: String
    let items: () -> [PanelMenu.Item]
    @State private var anchor = MenuAnchor.Box()

    var body: some View {
        IconButton(symbol: symbol, label: label) { PanelMenu.show(items(), under: anchor.view) }
            .background(MenuAnchor(box: anchor))
    }
}

/// An empty AppKit view in the button's place, so the menu can be put under the button.
struct MenuAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// The native menu behind `GlassMenuButton`.
@MainActor
final class PanelMenu: NSObject {
    enum Item {
        case action(String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true,
                    destructive: Bool = false, run: () -> Void)
        case separator
        /// A section's name, as the system's menus head their groups.
        case header(String)
        /// A line of explanation, not clickable.
        case note(String)
    }

    /// Kept until the next menu: the items' target must outlive the menu's tracking.
    private static var current: PanelMenu?
    private var actions: [() -> Void] = []

    static func show(_ items: [Item], under anchor: NSView? = nil) {
        let target = PanelMenu()
        current = target
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .header(let title):
                menu.addItem(.sectionHeader(title: title))
            case .note(let text):
                let row = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            case let .action(title, symbol, checked, enabled, destructive, run):
                let row = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
                row.target = target
                row.tag = target.actions.count
                target.actions.append(run)
                row.state = checked ? .on : .off
                row.isEnabled = enabled
                if let symbol { row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                if destructive {
                    row.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
                }
                menu.addItem(row)
            }
        }
        if let anchor {
            // Its top-left corner just under the button's bottom-left one.
            let below = anchor.isFlipped ? anchor.bounds.maxY + 6 : anchor.bounds.minY - 6
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.minX, y: below), in: anchor)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func run(_ sender: NSMenuItem) {
        actions[sender.tag]()
    }
}

/// The three things pairing needs, ticked off live. The panel shows them while nothing is paired,
/// and the welcome window shows them on its pairing page.
struct PairSteps: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // Read once per redraw: it walks the interfaces.
        let address = NetworkInfo.localIPv4()
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            OnboardingStep(
                number: 1,
                title: String(localized: "Install AndroMac on the phone and open it"),
                detail: nil,
                done: false
            )
            OnboardingStep(
                number: 2,
                title: String(localized: "Put both devices on the same Wi-Fi network"),
                detail: address.map { String(localized: "This Mac: \($0)") }
                    ?? String(localized: "This Mac has no local network"),
                done: address != nil
            )
            OnboardingStep(
                number: 3,
                title: String(localized: "Tap \"Pair\" on the phone"),
                detail: state.status.isLive
                    ? String(localized: "This Mac is visible on the network")
                    : String(localized: "Preparing to broadcast…"),
                done: state.status.isLive
            )
        }
    }
}

/// A numbered setup step; completed ones turn into a check mark.
struct OnboardingStep: View {
    let number: Int
    let title: String
    let detail: String?
    let done: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("\(number)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 15, height: 15)
                        .background(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                }
            }
            .font(Theme.Font.heading)
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A borderless, secondary action button — to keep box noise out of the panel.
struct QuietButton: View {
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Theme.Font.label)
            .foregroundStyle(.secondary)
    }
}

/// One notification in the panel. Folded, it is one line of text with the code to copy, a link or
/// the picture beside it; a click on it unfolds the whole text, selectable, with Copy text, Copy
/// code and Open link under it. One row is open at a time (MenuPanel).
struct NotificationRow: View {
    /// The panel list's height is the sum of these (MenuPanel), so the numbers live in one place.
    /// A row with a picture is taller by what the thumbnail needs; an open row by its text, which
    /// scrolls inside the row past `openTextMax`.
    static func height(_ entry: NotificationHistory.Entry, open: Bool = false) -> CGFloat {
        if open {
            let buttons = entry.buttons.isEmpty ? 0
                : NotificationActions.height(entry, inline: actionsInline(entry)) + Theme.Space.tight
            return iconSize + textHeight(entry) + actionsHeight + buttons + 2 * Theme.Space.tight + Theme.Space.small
        }
        return 34
    }

    /// Side by side when they fit beside the indent, as Reply and Mark as read do.
    private static func actionsInline(_ entry: NotificationHistory.Entry) -> Bool {
        NotificationActions.fitsInline(entry, width: textWidth)
    }

    /// Fits the folded row's height: a bigger picture made rows with one taller than the rest.
    static let pictureSize: CGFloat = 26
    private static let iconSize: CGFloat = 20
    private static let actionsHeight: CGFloat = 22
    private static let openTextMax: CGFloat = 180
    /// The open text starts under the app name: the icon and the gap after it.
    private static let textIndent = iconSize + Theme.Space.small
    /// The panel, less its inset on both sides, less the indent.
    private static let textWidth = Theme.panelWidth - 2 * Theme.panelInset - textIndent

    /// Measured with the font the text is drawn in, so the row is as tall as the text needs.
    private static func textHeight(_ entry: NotificationHistory.Entry) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11)
        let bounds = (fullText(entry) as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return min(ceil(bounds.height) + 2, openTextMax)
    }

    /// Title and text as the open row shows them, blank lines folded away.
    private static func fullText(_ entry: NotificationHistory.Entry) -> String {
        [entry.title, entry.text]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(NotificationMirror.tidy)
            .joined(separator: "\n")
    }

    let entry: NotificationHistory.Entry
    var open = false
    var onToggle: () -> Void = {}

    private var summary: String {
        [entry.title, entry.text]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// The one-time code in this notification, when there is one worth offering.
    private var code: String? { VerificationCode.find(in: summary) }

    @State private var copied: String?
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if open { openBody.transition(.opacity.combined(with: .offset(y: -6))) } else { foldedBody.transition(.opacity) }
        }
        .frame(height: Self.height(entry, open: open), alignment: .top)
        // The menu-item highlight macOS draws under the pointer, bled into the card's padding so
        // the text column does not move.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(.primary.opacity(hovered || open ? 0.06 : 0))
                .padding(.horizontal, -Theme.Space.tight - 2)
        }
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .contextMenu {
            if let code {
                Button(String(localized: "Copy code \(code)")) { put(code) }
            }
            if !summary.isEmpty {
                Button("Copy notification text") { put(Self.fullText(entry)) }
            }
        }
    }

    /// App and time on the first line, the text on the second, and a trailing slot of its own for
    /// the code to copy or the picture. The time used to sit at the text column's trailing edge,
    /// where a code button beside it squeezed both and left "now" floating mid-row.
    private var foldedBody: some View {
        HStack(alignment: .center, spacing: Theme.Space.small) {
            HStack(spacing: Theme.Space.small) {
                AppIcon(pkg: entry.pkg, fallback: entry.app, size: Self.iconSize)
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Text(summary.isEmpty ? String(localized: "Content hidden") : summary)
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Shows the whole notification"))
            if let code { copyCode(code) }
            else if let link = NotificationHistory.link(entry) { OpenLinkButton(url: link) }
            if entry.image != nil { NotificationPicture(entry: entry, size: Self.pictureSize) }
        }
        .frame(maxHeight: .infinity)
    }

    private var openBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.small) {
                AppIcon(pkg: entry.pkg, fallback: entry.app, size: Self.iconSize)
                header
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)

            ScrollView {
                Text(Self.fullText(entry))
                    .font(Theme.Font.label)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(height: Self.textHeight(entry))
            .padding(.leading, Self.textIndent)

            HStack(spacing: Theme.Space.tight) {
                if let code { copyCode(code) }
                copyButton(String(localized: "Copy text"), value: Self.fullText(entry), symbol: "doc.on.doc")
                if let link = NotificationHistory.link(entry) {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        Label("Open link", systemImage: "arrow.up.right.square")
                    }
                    .help(link.absoluteString)
                    .buttonBorderShape(.capsule)
                    .secondaryAction()
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .font(Theme.Font.label)
            .frame(height: Self.actionsHeight)
            .padding(.leading, Self.textIndent)

            if !entry.buttons.isEmpty {
                NotificationActions(entry: entry, inline: Self.actionsInline(entry))
                    .padding(.leading, Self.textIndent)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.tight) {
            Text(entry.app)
                .font(Theme.Font.label.weight(.medium))
                .lineLimit(1)
            Text(verbatim: "·").foregroundStyle(.secondary)
            // Never cut: the app name gives way first.
            RelativeTime(date: entry.date)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .font(Theme.Font.label)
    }

    /// The code itself on a small glass button: readable without opening anything, one click
    /// saves retyping it. Fixed at its own size, so the text column is what gives way.
    private func copyCode(_ code: String) -> some View {
        copyButton(code, value: code, symbol: "doc.on.doc", monospaced: true)
            .help("Copy this code to the Mac clipboard")
            .accessibilityLabel("Copy code \(code)")
    }

    private func copyButton(_ title: String, value: String, symbol: String, monospaced: Bool = false) -> some View {
        Button {
            put(value)
        } label: {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: copied == value ? "checkmark" : symbol)
                    .contentTransition(.symbolEffect(.replace))
                if monospaced { Text(verbatim: title).monospacedDigit() } else { Text(verbatim: title) }
            }
            .font(Theme.Font.label)
            .foregroundStyle(copied == value ? Color.green : Color.primary)
        }
        .buttonBorderShape(.capsule)
        .secondaryAction()
        .controlSize(.small)
        .fixedSize()
    }

    /// Put it on the Mac clipboard WITHOUT sending it back to the phone.
    ///
    /// `restore` arms the echo breaker, which matters twice here: the text came from the phone in
    /// the first place, so returning it is pointless traffic, and a one-time code is exactly the
    /// kind of value that should not travel further than it has to. It also stays out of the
    /// clipboard history for the same reason.
    private func put(_ text: String) {
        Task {
            await ClipboardWatcher.shared.restore(text)
            copied = text
            try? await Task.sleep(for: .milliseconds(1200))
            if copied == text { copied = nil }
        }
    }
}

/// One copy in the panel. Folded, it is one line with a copy button under the pointer; a click
/// unfolds the whole text, selectable, with Copy and Open link under it. One row is open at a
/// time (MenuPanel), and the list's height is the sum of `height`.
struct ClipRow: View {
    static let foldedHeight: CGFloat = 26
    private static let actionsHeight: CGFloat = 22
    private static let openTextMax: CGFloat = 160
    /// The open text starts under the folded text: the icon column and the gap after it.
    private static let indent: CGFloat = 14 + Theme.Space.small
    private static let textWidth = Theme.panelWidth - 2 * Theme.panelInset - indent

    static func height(_ text: String, open: Bool) -> CGFloat {
        guard open else { return foldedHeight }
        return foldedHeight + textHeight(text) + Theme.Space.tight + actionsHeight + Theme.Space.small
    }

    /// Measured with the font the text is drawn in, so the row is as tall as the text needs.
    private static func textHeight(_ text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
        return min(ceil(bounds.height) + 2, openTextMax)
    }

    let text: String
    let direction: ClipboardHistory.Direction
    var open = false
    var copied = false
    let onToggle: () -> Void
    let onCopy: () -> Void
    let onOpenHistory: () -> Void

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.small) {
                HStack(spacing: Theme.Space.small) {
                    Image(systemName: copied ? "checkmark" : direction.symbol)
                        .font(Theme.Font.label)
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                        .frame(width: 14)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: copied)
                        .accessibilityLabel(direction.label)
                    Group {
                        if open {
                            Text(direction.label).font(Theme.Font.label).foregroundStyle(.secondary)
                        } else {
                            Text(trimmed.replacingOccurrences(of: "\n", with: " ")).font(Theme.Font.body)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("Shows the whole text"))
                if open {
                    Image(systemName: "chevron.up")
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else if hovered || copied {
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc",
                               label: String(localized: "Copy to the Mac clipboard"), active: copied, action: onCopy)
                }
            }
            .frame(height: Self.foldedHeight)

            if open {
                openBody
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .frame(height: Self.height(text, open: open), alignment: .top)
        .clipped()
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(.primary.opacity(hovered || open ? 0.06 : 0))
                .padding(.horizontal, -Theme.Space.tight - 2)
        }
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .help(open ? "" : String(text.prefix(600)))
        .contextMenu {
            Button("Copy", action: onCopy)
            Button("Open clipboard history", action: onOpenHistory)
        }
    }

    @ViewBuilder
    private var openBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
                ScrollView {
                    Text(trimmed)
                        .font(Theme.Font.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: Self.textHeight(trimmed))
                .padding(.leading, Self.indent)

                HStack(spacing: Theme.Space.tight) {
                    Button(action: onCopy) {
                        Label(copied ? String(localized: "Copied") : String(localized: "Copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    if let link = WebLink.find(in: trimmed) {
                        Button { NSWorkspace.shared.open(link) } label: {
                            Label("Open link", systemImage: "arrow.up.right.square")
                        }
                        .help(link.absoluteString)
                    }
                    Spacer(minLength: 0)
                }
                .buttonBorderShape(.capsule)
                .secondaryAction()
                .controlSize(.small)
                .font(Theme.Font.label)
                .frame(height: Self.actionsHeight)
                .padding(.leading, Self.indent)
                .glassGroup(spacing: Theme.Space.tight)
        }
    }
}

/// The track playing on the phone plus three controls. No progress bar (PROTOCOL §6.10):
/// syncing the position would mean a message every second.
struct MediaRow: View {
    let media: AppState.Media
    /// The phone playing it. With two phones, Next must skip the track on this one only.
    let deviceID: String

    var body: some View {
        HStack(spacing: Theme.Space.small) {
            AppIcon(pkg: media.pkg, fallback: media.app, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(media.title)
                    .font(Theme.Font.body)
                    .lineLimit(1)
                byline
            }
            Spacer(minLength: Theme.Space.tight)
            control("backward.fill", label: String(localized: "Previous"), cmd: "previous")
            control(media.playing ? "pause.fill" : "play.fill",
                    label: media.playing
                        ? String(localized: "Pause") : String(localized: "Play"),
                    cmd: media.playing ? "pause" : "play")
            control("forward.fill", label: String(localized: "Next"), cmd: "next")
        }
        .glassGroup(spacing: Theme.Space.tight)
        .frame(height: 30)
    }

    /// Players pad the artist field ("SELIN • Recommended for you"); the part before the first
    /// bullet is the artist.
    private var artist: String {
        let name = media.artist.components(separatedBy: " • ").first ?? ""
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// The artist on its own line, whole; the app after it only while both fit, dropped before the
    /// artist would be cut.
    @ViewBuilder
    private var byline: some View {
        let artistText = Text(artist)
            .font(Theme.Font.label)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        let app = media.app == artist ? "" : media.app
        if artist.isEmpty {
            if !app.isEmpty { Text(app).font(Theme.Font.label).foregroundStyle(.secondary).lineLimit(1) }
        } else if app.isEmpty {
            artistText
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.tight) {
                    artistText
                    Text(verbatim: "·").font(Theme.Font.caption).foregroundStyle(.tertiary)
                    Text(app).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
                artistText
            }
        }
    }

    private func control(_ symbol: String, label: String, cmd: String) -> some View {
        IconButton(symbol: symbol, label: label) {
            let deviceID = deviceID
            Task { await Server.shared.send(["t": "media_control", "cmd": cmd], to: deviceID) }
        }
    }
}

/// One phone's battery, compact enough for the phone's header line: the level glyph, the
/// percentage and a bolt while charging. The state and temperature are in the tooltip. The only
/// place the panel prints this phone's percentage.
struct BatteryLine: View {

    let battery: AppState.Battery

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            if battery.charging {
                Image(systemName: "bolt.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.green)
            }
            Text("\(battery.level)%")
                .font(Theme.Font.label.weight(.medium).monospacedDigit())
                .contentTransition(.numericText(value: Double(battery.level)))
                .animation(.snappy(duration: 0.3), value: battery.level)
            Image(systemName: symbol)
                .font(Theme.Font.body)
                .foregroundStyle(tint)
        }
        .fixedSize()
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Battery \(battery.level)%, \(detail)"))
    }

    private var symbol: String {
        switch battery.level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var tint: Color {
        if battery.charging { return .green }
        switch battery.level {
        case ..<15: return .red
        case ..<30: return .orange
        default: return .secondary
        }
    }

    private var detail: String {
        var parts = [Self.label(battery.status)]
        if let t = battery.temperature { parts.append(String(format: "%.0f°C", t)) }
        return parts.joined(separator: " · ")
    }

    private static func label(_ status: String) -> String {
        switch status {
        case "charging": return String(localized: "charging")
        case "full": return String(localized: "full")
        case "discharging": return String(localized: "in use")
        case "not_charging": return String(localized: "not charging")
        default: return String(localized: "unknown")
        }
    }
}
