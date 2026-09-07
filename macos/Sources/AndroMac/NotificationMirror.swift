import AppKit
import CryptoKit
import Foundation
import UserNotifications

/// Shows the phone's notifications in the macOS Notification Center and sends actions back.
@MainActor
final class NotificationMirror: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationMirror()
    fileprivate static let muteIdentifier = "andromac.mute"

    private let center = UNUserNotificationCenter.current()
    private var categories: [String: UNNotificationCategory] = [:]

    func bootstrap() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { NSLog("AndroMac: notification permission error — \(error.localizedDescription)") }
            else if !granted { NSLog("AndroMac: notification permission was not granted") }
        }
    }

    // MARK: presenting

    func show(_ msg: [String: Any]) {
        // Incoming fields are untrusted: we do not assume the sender clipped them (PROTOCOL,
        // incoming data limits). A notification with an empty `id` cannot be correlated, so the
        // message is dropped.
        let id = clip(msg["id"], 256)
        guard !id.isEmpty else { return }
        let app = clip(msg["app"], 256)
        let pkg = clip(msg["pkg"], 256)
        let title = clip(msg["title"], 2048)
        let text = clip(msg["text"], 2048)
        let silent = msg["silent"] as? Bool == true

        // The TITLE_ONLY tier: the content never left the phone, and we do not invent it here either.
        let redacted = msg["redacted"] as? Bool ?? false

        let content = UNMutableNotificationContent()
        content.title = redacted ? app : title
        content.subtitle = redacted ? "" : app
        content.body = redacted ? String(localized: "Content hidden") : text
        content.sound = silent ? nil : .default
        // `silent` is needed at presentation time too: willPresent is the only place that suppresses the banner.
        content.userInfo = ["id": id, "pkg": pkg, "silent": silent]
        if silent { content.interruptionLevel = .passive }

        // A category is ALWAYS registered: even with no actions we still offer "Mute".
        content.categoryIdentifier = registerCategory(for: parseActions(msg["actions"]))

        // Attach the app icon as a badge; if it is missing, ask the phone for it (once).
        // The temporary copy is handed to UserNotifications and deleted after `add` completes (or
        // right away if the attachment cannot be built) — otherwise every notification would leave
        // a file behind in /tmp.
        var temporaryIcon: URL?
        if !pkg.isEmpty {
            if let icon = IconCache.shared.temporaryCopy(for: pkg) {
                if let attachment = try? UNNotificationAttachment(identifier: "icon", url: icon) {
                    content.attachments = [attachment]
                    temporaryIcon = icon
                } else {
                    try? FileManager.default.removeItem(at: icon)
                }
            } else {
                IconCache.shared.requestIfMissing(pkg)
            }
        }

        NotificationHistory.shared.add(
            .init(id: id, app: app, pkg: pkg, title: title, text: text, date: Date())
        )

        let iconToRemove = temporaryIcon
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { NSLog("AndroMac: could not present the notification — \(error.localizedDescription)") }
            if let iconToRemove { try? FileManager.default.removeItem(at: iconToRemove) }
        }
    }

    /// A single warning so the phone's battery does not die while it is out of reach.
    ///
    /// The identifier carries the device, so successive warnings from ONE phone replace each other
    /// while two phones can each have their own — a shared identifier would let the second phone's
    /// warning quietly overwrite the first one's.
    func showLowBattery(level: Int, phone: String) {
        let content = UNMutableNotificationContent()
        content.title = AppState.displayName(phone).map { String(localized: "\($0)'s battery is low") }
            ?? String(localized: "Your phone's battery is low")
        content.body = String(localized: "\(level)% — plug in the charger")
        content.sound = .default
        center.add(
            UNNotificationRequest(
                identifier: "andromac.lowbattery.\(phone)", content: content, trigger: nil
            )
        ) { error in
            if let error { NSLog("AndroMac: could not present the battery warning — \(error.localizedDescription)") }
        }
    }

    /// Dismissed on the phone — remove it on the Mac too.
    func remove(_ id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func clip(_ value: Any?, _ limit: Int) -> String {
        String((value as? String ?? "").prefix(limit))
    }

    // MARK: categories

    private struct Action { let title: String; let reply: Bool }

    private func parseActions(_ raw: Any?) -> [Action] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap {
            guard let title = $0["title"] as? String, !title.isEmpty else { return nil }
            return Action(title: title, reply: $0["reply"] as? Bool ?? false)
        }
    }

    /// A UNNotificationCategory has to be registered in advance. Since the action list differs per
    /// app, we use an identifier derived from its signature and register it on demand.
    private func registerCategory(for actions: [Action]) -> String {
        let signature = (actions.map { ($0.reply ? "r:" : "n:") + $0.title } + ["mute"])
            .joined(separator: "|")
        let id = "am." + SHA256.hash(data: Data(signature.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        if categories[id] != nil { return id }

        var unActions: [UNNotificationAction] = actions.enumerated().map { index, a in
            a.reply
                ? UNTextInputNotificationAction(
                    identifier: "a\(index)", title: a.title, options: [],
                    textInputButtonTitle: String(localized: "Send"), textInputPlaceholder: "")
                : UNNotificationAction(identifier: "a\(index)", title: a.title, options: [])
        }
        // Muting straight from the notification: the most used action, without leaving the keyboard.
        unActions.append(
            UNNotificationAction(identifier: Self.muteIdentifier,
                                 title: String(localized: "Mute this app"),
                                 options: [.destructive])
        )
        categories[id] = UNNotificationCategory(
            identifier: id, actions: unActions, intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories(Set(categories.values))
        return id
    }

    // MARK: delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // PROTOCOL §6.9 — the existing notifications delivered on connect are marked `silent`;
        // showing banners would mean a shower of pop-ups on every connect. They only land in the list.
        let silent = notification.request.content.userInfo["silent"] as? Bool == true
        return silent ? [.list] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo
        let pkg = userInfo["pkg"] as? String ?? ""

        // "File received" (FileTransfer): a click reveals the file in Finder, it is never opened.
        if let path = userInfo["file"] as? String {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            return
        }

        switch response.actionIdentifier {
        case Self.muteIdentifier:
            guard !pkg.isEmpty else { return }
            await AppModes.shared.set(.off, for: pkg)

        case UNNotificationDismissActionIdentifier:
            await Server.shared.send(["t": "notification_dismiss", "id": id])

        case UNNotificationDefaultActionIdentifier:
            break        // a plain click: do nothing on the phone

        case let identifier where identifier.hasPrefix("a"):
            guard let index = Int(identifier.dropFirst()) else { return }
            var msg: [String: Any] = ["t": "notification_action", "id": id, "action": index]
            if let textResponse = response as? UNTextInputNotificationResponse {
                msg["reply"] = textResponse.userText
            }
            await Server.shared.send(msg)

        default:
            break
        }
    }
}
