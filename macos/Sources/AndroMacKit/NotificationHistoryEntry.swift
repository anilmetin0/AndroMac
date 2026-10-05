import Foundation

public struct NotificationHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: String          // Source phone + StatusBarNotification.key
    public let app: String
    public let pkg: String
    public let title: String
    public let text: String
    public let date: Date
    /// The picture or avatar file in `images/`, when the phone sent one. Optional, so a
    /// history written before pictures still decodes.
    public let image: String?

    public let peer: String?
    public let notificationID: String?
    public let actions: [NotificationAction]?

    public var phoneID: String { notificationID ?? id }
    public var buttons: [NotificationAction] { actions ?? [] }

    public init(id: String, app: String, pkg: String, title: String, text: String, date: Date, image: String? = nil, peer: String? = nil, actions: [NotificationAction]? = nil) {
        self.id = peer.map { "\($0)/\(id)" } ?? id
        self.app = app; self.pkg = pkg
        self.title = title; self.text = text; self.date = date; self.image = image
        self.peer = peer; self.notificationID = peer == nil ? nil : id; self.actions = actions
    }
}

