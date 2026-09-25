import AndroMacKit
import AppKit
import SwiftUI

// The small building blocks of the menu bar panel.

/// A group of related rows on its own plate.
///
/// Content, not control: a plain quiet fill, never glass. The controls inside it carry the glass.
/// The corner is concentric with the panel's (`panelCard`).
struct PanelCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            content
        }
        .padding(Theme.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(Color.primary.opacity(0.06))
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
        }
        .glassIcon()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A round glass button that opens a native menu. SwiftUI's `Menu` does not take the glass button
/// style (it drew a flat disc), and glass laid over it swallowed its clicks; this is the same
/// `IconButton` as every other panel action, with an `NSMenu` behind the click.
struct GlassMenuButton: View {
    let symbol: String
    let label: String
    let items: () -> [PanelMenu.Item]

    var body: some View {
        IconButton(symbol: symbol, label: label) { PanelMenu.show(items()) }
    }
}

/// The native menu behind `GlassMenuButton`, opened under the pointer.
@MainActor
final class PanelMenu: NSObject {
    enum Item {
        case action(String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, run: () -> Void)
        case separator
        /// A line of explanation, not clickable.
        case note(String)
    }

    /// Kept until the next menu: the items' target must outlive the menu's tracking.
    private static var current: PanelMenu?
    private var actions: [() -> Void] = []

    static func show(_ items: [Item]) {
        let target = PanelMenu()
        current = target
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .note(let text):
                let row = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            case let .action(title, symbol, checked, enabled, run):
                let row = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
                row.target = target
                row.tag = target.actions.count
                target.actions.append(run)
                row.state = checked ? .on : .off
                row.isEnabled = enabled
                if let symbol { row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                menu.addItem(row)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func run(_ sender: NSMenuItem) {
        actions[sender.tag]()
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
        if open { return iconSize + textHeight(entry) + actionsHeight + 2 * Theme.Space.tight + Theme.Space.small }
        return entry.image == nil ? 36 : pictureSize + Theme.Space.small
    }

    static let pictureSize: CGFloat = 40
    private static let iconSize: CGFloat = 24
    private static let actionsHeight: CGFloat = 22
    private static let openTextMax: CGFloat = 180
    /// The open text starts under the app name: the icon and the gap after it.
    private static let textIndent = iconSize + Theme.Space.small
    /// The panel, less its inset and the card's padding on both sides, less the indent.
    private static let textWidth = Theme.panelWidth - 2 * Theme.panelInset - 2 * Theme.Space.medium - textIndent

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

    var body: some View {
        Group {
            if open { openBody } else { foldedBody }
        }
        .frame(height: Self.height(entry, open: open), alignment: .top)
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
        Button {
            let deviceID = deviceID
            Task { await Server.shared.send(["t": "media_control", "cmd": cmd], to: deviceID) }
        } label: {
            Image(systemName: symbol)
                .font(Theme.Font.body)
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// One phone's battery on one line: the level glyph, the percentage, a bolt while charging, and the
/// state and temperature as quiet secondary text. The only place the panel prints this phone's
/// percentage.
struct BatteryLine: View {

    let battery: AppState.Battery

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            Image(systemName: symbol)
                .font(Theme.Font.body)
                .foregroundStyle(tint)
            Text("\(battery.level)%")
                .font(Theme.Font.body.weight(.medium).monospacedDigit())
            if battery.charging {
                Image(systemName: "bolt.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.green)
            }
            Text(detail)
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
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
