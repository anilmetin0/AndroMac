import AndroMacKit
import AppKit
import CryptoKit
import Foundation
import UserNotifications

/// Shows the phone's notifications in the macOS Notification Center and sends actions back.
@MainActor
final class NotificationMirror: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationMirror()
    fileprivate static let muteIdentifier = "andromac.mute"
    fileprivate static let linkIdentifier = "andromac.link"

    private let center = UNUserNotificationCenter.current()
    private var categories: [String: UNNotificationCategory] = [:]

    func bootstrap() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { NSLog("AndroMac: notification permission error — \(error.localizedDescription)") }
            else if !granted { NSLog("AndroMac: notification permission was not granted") }
            Task { @MainActor in self.refreshAuthorization() }
        }
    }

    /// Re-read the system grant so the Permissions row reflects a change made in System Settings.
    func refreshAuthorization() {
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor in AppState.shared.notificationsAuthorized = allowed }
        }
    }

    // MARK: presenting

    /// The Notification Center identifier carries the phone: two phones can post notifications
    /// with the same key (`0|com.whatsapp|1|null|10234`), and a reply must go back to the one
    /// that posted it.
    private static func identifier(_ id: String, peer: String) -> String { "\(peer)/\(id)" }

    /// `image` is the message's `img`, already validated and re-encoded off the main thread
    /// (Server); nil when there was none, or when the phone sent none because it already did.
    func show(_ msg: [String: Any], image: NotificationImage.Clean?, from peer: String) {
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

        // Every reconnect (and so every wake of the Mac) replays the phone's current
        // notifications, silently. One this Mac already shows, unchanged, is skipped before the
        // icon copy, the Notification Center request and the history rewrite.
        // A replay that brings a picture is new, however: the phone sends one only when it changed.
        let history = NotificationHistory.shared
        if silent, image == nil, history.contains(id: id, title: title, text: text) { return }

        let content = UNMutableNotificationContent()
        content.title = redacted ? app : title
        content.subtitle = redacted ? "" : app
        content.body = redacted ? String(localized: "Content hidden") : text
        content.sound = (silent || !Store.shared.notificationSound) ? nil : .default
        // `silent` is needed at presentation time too: willPresent is the only place that suppresses the banner.
        content.userInfo = ["id": id, "pkg": pkg, "silent": silent, "peer": peer]
        if silent { content.interruptionLevel = .passive }
        // A web address in the text gets an Open link button; never on a redacted notification.
        let link = redacted ? nil : WebLink.find(in: title + "\n" + text)
        if let link { content.userInfo["link"] = link.absoluteString }

        // A category is ALWAYS registered: even with no actions we still offer "Mute".
        content.categoryIdentifier = registerCategory(for: NotificationAction.parse(msg["actions"]), link: link != nil)

        // Every package without an icon on disk is asked for once per session, whatever this
        // notification attaches: the panel and the lists draw the icon too.
        if !pkg.isEmpty { IconCache.shared.requestIfMissing(pkg, from: peer) }

        // The picture: a new one, else the one this notification already had (a text-only update
        // brings none). Never on a redacted notification, and a stale one is deleted with the entry.
        let imageName = redacted ? nil : (image.flatMap(history.saveImage) ?? history.image(forID: id))

        // Attach the picture or avatar if there is one, the app icon otherwise. The temporary copy
        // is handed to UserNotifications and deleted after `add` completes (or right away if the
        // attachment cannot be built) — otherwise every notification would leave a file in /tmp.
        // The picture is decrypted into that temporary file only; UserNotifications needs a file.
        var temporaryFile: URL?
        let pictureData = image?.data ?? history.imageData(named: imageName)
        let picture = pictureData.flatMap { data in
            imageName.flatMap { Self.temporaryFile(data, extension: ($0 as NSString).pathExtension) }
        }
        let icon = pkg.isEmpty ? nil : IconCache.shared.cachedURL(for: pkg).flatMap(Self.temporaryCopy(of:))
        if picture != nil, let icon { try? FileManager.default.removeItem(at: icon) }
        if let copy = picture ?? icon {
            if let attachment = try? UNNotificationAttachment(identifier: "image", url: copy) {
                content.attachments = [attachment]
                temporaryFile = copy
            } else {
                try? FileManager.default.removeItem(at: copy)
            }
        }

        history.add(
            .init(id: id, app: app, pkg: pkg, title: title, text: text, date: Date(), image: imageName),
            silent: silent
        )

        let iconToRemove = temporaryFile
        center.add(UNNotificationRequest(identifier: Self.identifier(id, peer: peer), content: content, trigger: nil)) { error in
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
    func remove(_ id: String, from peer: String) {
        let identifier = Self.identifier(id, peer: peer)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// UserNotifications MOVES the attachment file into its own store, so it gets a fresh copy
    /// each time; the extension stays, since that is how it tells a JPEG from a PNG.
    private static func temporaryFile(_ data: Data, extension ext: String) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("andromac-\(UUID().uuidString).\(ext)")
        return FileManager.default.createFile(atPath: destination.path, contents: data,
                                              attributes: [.posixPermissions: 0o600]) ? destination : nil
    }

    private static func temporaryCopy(of source: URL) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("andromac-\(UUID().uuidString).\(source.pathExtension)")
        return (try? FileManager.default.copyItem(at: source, to: destination)) == nil ? nil : destination
    }

    private func clip(_ value: Any?, _ limit: Int) -> String {
        String((value as? String ?? "").prefix(limit))
    }

    // MARK: categories

    /// A UNNotificationCategory has to be registered in advance. Since the action list differs per
    /// app, we use an identifier derived from its signature and register it on demand.
    private func registerCategory(for actions: [NotificationAction], link: Bool) -> String {
        let signature = (actions.map { ($0.reply ? "r\($0.index):" : "n\($0.index):") + $0.title }
            + (link ? ["link"] : []) + ["mute"])
            .joined(separator: "|")
        let id = "am." + SHA256.hash(data: Data(signature.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        if categories[id] != nil { return id }
        // One category per distinct action list, so the set is bounded: past 64 it starts over.
        // A notification still on screen with a dropped category loses only its buttons.
        if categories.count >= 64 { categories.removeAll() }

        var unActions: [UNNotificationAction] = actions.map { a in
            a.reply
                ? UNTextInputNotificationAction(
                    identifier: "a\(a.index)", title: a.title, options: [],
                    textInputButtonTitle: String(localized: "Send"), textInputPlaceholder: "")
                : UNNotificationAction(identifier: "a\(a.index)", title: a.title, options: [])
        }
        if link {
            unActions.append(UNNotificationAction(identifier: Self.linkIdentifier,
                                                  title: String(localized: "Open link"), options: []))
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
        let userInfo = response.notification.request.content.userInfo
        let id = userInfo["id"] as? String ?? ""
        let pkg = userInfo["pkg"] as? String ?? ""
        let peer = userInfo["peer"] as? String ?? ""

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
        case Self.linkIdentifier:
            // Checked again here: userInfo comes back from the system, and only the web is opened.
            guard let string = userInfo["link"] as? String, let url = URL(string: string), WebLink.isWeb(url) else { return }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }

        case Self.muteIdentifier:
            guard !pkg.isEmpty else { return }
            await AppModes.shared.set(.off, for: pkg, on: peer)

        case UNNotificationDismissActionIdentifier:
            await Server.shared.send(["t": "notification_dismiss", "id": id], to: peer)

        case UNNotificationDefaultActionIdentifier:
            break        // a plain click: do nothing on the phone

        case let identifier where identifier.hasPrefix("a"):
            guard let index = Int(identifier.dropFirst()) else { return }
            var msg: [String: Any] = ["t": "notification_action", "id": id, "action": index]
            if let textResponse = response as? UNTextInputNotificationResponse {
                msg["reply"] = textResponse.userText
            }
            await Server.shared.send(msg, to: peer)

        default:
            break
        }
    }
}
