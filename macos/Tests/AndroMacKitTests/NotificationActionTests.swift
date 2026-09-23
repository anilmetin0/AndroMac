import Testing
@testable import AndroMacKit

struct NotificationActionTests {

    /// Each distinct list registers a notification category, so what the phone sends is bounded.
    @Test func keepsThreeActionsWithClippedTitles() {
        let raw: [[String: Any]] = (0..<6).map { ["title": String(repeating: "x", count: 100 + $0), "reply": $0 == 1] }
        let actions = NotificationAction.parse(raw)
        #expect(actions.count == NotificationAction.maxCount)
        #expect(actions.allSatisfy { $0.title.count == NotificationAction.maxTitle })
        #expect(actions.map(\.reply) == [false, true, false])
    }

    /// `notification_action` sends the index into the phone's list, so a skipped entry must not
    /// shift the ones after it.
    @Test func keepsThePhonesIndexPastSkippedEntries() {
        let raw: [[String: Any]] = [["title": ""], ["reply": true], ["title": "Reply", "reply": true], ["title": "Read"]]
        let actions = NotificationAction.parse(raw)
        #expect(actions == [NotificationAction(index: 2, title: "Reply", reply: true),
                            NotificationAction(index: 3, title: "Read", reply: false)])
        #expect(NotificationAction.parse(nil).isEmpty)
        #expect(NotificationAction.parse("junk").isEmpty)
    }
}
