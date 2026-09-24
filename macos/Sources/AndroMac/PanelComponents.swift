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

struct NotificationRow: View {
    /// The panel list's height is the sum of these (MenuPanel), so the numbers live in one place.
    /// A row with a picture is taller by what the thumbnail needs.
    static func height(_ entry: NotificationHistory.Entry) -> CGFloat {
        entry.image == nil ? 36 : pictureSize + Theme.Space.small
    }

    static let pictureSize: CGFloat = 40

    let entry: NotificationHistory.Entry

    private var summary: String {
        [entry.title, entry.text]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// The one-time code in this notification, when there is one worth offering.
    private var code: String? { VerificationCode.find(in: summary) }

    @State private var copied = false

    /// App and time on the first line, the text on the second, and a trailing slot of its own for
    /// the code to copy or the picture. The time used to sit at the text column's trailing edge,
    /// where a code button beside it squeezed both and left "now" floating mid-row.
    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.small) {
            AppIcon(pkg: entry.pkg, fallback: entry.app, size: 24)
            VStack(alignment: .leading, spacing: 0) {
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
                Text(summary.isEmpty ? String(localized: "Content hidden") : summary)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let code { copyCode(code) }
            else if let link = NotificationHistory.link(entry) { OpenLinkButton(url: link) }
            if entry.image != nil { NotificationPicture(entry: entry, size: Self.pictureSize) }
        }
        .frame(height: Self.height(entry))
        .contextMenu {
            if let code {
                Button(String(localized: "Copy code \(code)")) { put(code) }
            }
            if !summary.isEmpty {
                Button("Copy notification text") { put(summary) }
            }
        }
    }

    /// The code itself on a small glass button: readable without opening anything, one click
    /// saves retyping it. Fixed at its own size, so the text column is what gives way.
    private func copyCode(_ code: String) -> some View {
        Button {
            put(code)
        } label: {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                Text(verbatim: code).monospacedDigit()
            }
            .font(Theme.Font.label)
            .foregroundStyle(copied ? Color.green : Color.primary)
        }
        .buttonBorderShape(.capsule)
        .secondaryAction()
        .controlSize(.small)
        .fixedSize()
        .help("Copy this code to the Mac clipboard")
        .accessibilityLabel("Copy code \(code)")
    }

    /// Put it on the Mac clipboard WITHOUT sending it back to the phone.
    ///
    /// `restore` arms the echo breaker, which matters twice here: the code came from the phone in
    /// the first place, so returning it is pointless traffic, and a one-time code is exactly the
    /// kind of value that should not travel further than it has to. It also stays out of the
    /// clipboard history for the same reason.
    private func put(_ text: String) {
        Task {
            await ClipboardWatcher.shared.restore(text)
            copied = true
            try? await Task.sleep(for: .milliseconds(1200))
            copied = false
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
