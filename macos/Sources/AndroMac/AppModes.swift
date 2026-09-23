import Foundation
import SwiftUI

/// The Mac's mirror of the per-app tiers on the phone.
///
/// The filter is applied ON THE PHONE (PROTOCOL §6.6); this list exists only to display them and
/// to change them remotely. A change goes to the phone as `app_mode`, the phone applies it and
/// sends the current list back as `app_modes` — the phone is the single source of truth.
@MainActor
final class AppModes: ObservableObject {

    static let shared = AppModes()

    enum Mode: Int, CaseIterable, Identifiable {
        case off = 0
        case titleOnly = 1
        case full = 2

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .off: return String(localized: "Off")
            case .titleOnly: return String(localized: "Title only")
            case .full: return String(localized: "Full")
            }
        }

        var symbol: String {
            switch self {
            case .off: return "bell.slash"
            case .titleOnly: return "eye.slash"
            case .full: return "bell"
            }
        }
    }

    struct App: Identifiable, Equatable {
        let pkg: String
        let label: String
        var mode: Mode
        var id: String { pkg }
    }

    /// Per phone: each one has its own apps and its own tiers, and its `app_modes` must not
    /// overwrite another phone's list. Keyed by `PairedDevice.id`.
    @Published private var byDevice: [String: [App]] = [:]

    /// The phone the Apps tab and the panel are showing.
    private var focused: String? { AppState.shared.focusedDevice?.id }

    /// The focused phone's apps, which is what the Apps tab lists.
    var apps: [App] { focused.flatMap { byDevice[$0] } ?? [] }

    func replace(with raw: [[String: Any]], from peer: String) {
        byDevice[peer] = raw.compactMap { item in
            guard let pkg = item["pkg"] as? String, !pkg.isEmpty else { return nil }
            return App(
                pkg: String(pkg.prefix(256)),
                label: String((item["label"] as? String ?? pkg).prefix(200)),
                mode: Mode(rawValue: item["mode"] as? Int ?? 2) ?? .full
            )
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// An optimistic update on one phone; replaced once it confirms with `app_modes`. `peer` nil
    /// means the focused phone (the Apps tab). Rolled back if the send fails: with no connection
    /// (the "Mute" action on a notification also lands here) the UI used to show "applied" while
    /// nothing changed on the phone.
    func set(_ mode: Mode, for pkg: String, on peer: String? = nil) {
        guard let peer = peer ?? focused else { return }
        let previous = byDevice[peer]?.first { $0.pkg == pkg }?.mode
        if let index = byDevice[peer]?.firstIndex(where: { $0.pkg == pkg }) {
            byDevice[peer]?[index].mode = mode
        }
        Task {
            let sent = await Server.shared.send(["t": "app_mode", "pkg": pkg, "mode": mode.rawValue], to: peer)
            if !sent, let previous, let index = self.byDevice[peer]?.firstIndex(where: { $0.pkg == pkg }) {
                self.byDevice[peer]?[index].mode = previous
            }
        }
    }

    func clear() { byDevice = [:] }
}
