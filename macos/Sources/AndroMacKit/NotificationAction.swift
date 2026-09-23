import Foundation

/// One action button of a mirrored notification (PROTOCOL §5 `notification.actions`).
///
/// Every distinct list of actions becomes a registered `UNNotificationCategory`, so what the phone
/// sends is bounded here: at most `maxCount` actions, each title at most `maxTitle` characters.
public struct NotificationAction: Equatable, Sendable {
    /// The position in the phone's list, which is what `notification_action` sends back.
    public let index: Int
    public let title: String
    public let reply: Bool

    public static let maxCount = 3
    public static let maxTitle = 64

    public init(index: Int, title: String, reply: Bool) {
        self.index = index
        self.title = title
        self.reply = reply
    }

    /// The first `maxCount` actions with a title, clipped; anything malformed is skipped.
    public static func parse(_ raw: Any?) -> [NotificationAction] {
        guard let list = raw as? [[String: Any]] else { return [] }
        let actions = list.enumerated().compactMap { index, item -> NotificationAction? in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            return NotificationAction(index: index, title: String(title.prefix(maxTitle)),
                                      reply: item["reply"] as? Bool ?? false)
        }
        return Array(actions.prefix(maxCount))
    }
}
