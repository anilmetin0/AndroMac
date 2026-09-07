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

    @Published private(set) var apps: [App] = []

    func replace(with raw: [[String: Any]]) {
        apps = raw.compactMap { item in
            guard let pkg = item["pkg"] as? String, !pkg.isEmpty else { return nil }
            return App(
                pkg: pkg,
                label: item["label"] as? String ?? pkg,
                mode: Mode(rawValue: item["mode"] as? Int ?? 2) ?? .full
            )
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func mode(for pkg: String) -> Mode {
        apps.first { $0.pkg == pkg }?.mode ?? .full
    }

    /// An optimistic update; replaced once the phone confirms it with `app_modes`.
    /// Rolled back if the send fails: with no connection (the "Mute" action on a notification also
    /// lands here) the UI used to show "applied" while nothing changed on the phone.
    func set(_ mode: Mode, for pkg: String) {
        let previous = apps.first { $0.pkg == pkg }?.mode
        if let index = apps.firstIndex(where: { $0.pkg == pkg }) {
            apps[index].mode = mode
        }
        Task {
            let sent = await Server.shared.send(["t": "app_mode", "pkg": pkg, "mode": mode.rawValue])
            if !sent, let previous, let index = self.apps.firstIndex(where: { $0.pkg == pkg }) {
                self.apps[index].mode = previous
            }
        }
    }

    func clear() { apps = [] }
}
