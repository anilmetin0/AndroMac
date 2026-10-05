import Foundation
import Testing
@testable import AndroMacKit

struct NotificationHistoryEntryTests {
    @Test func legacyHistoryStillLoads() throws {
        let data = Data(#"{"id":"key","app":"Messages","pkg":"messages","title":"Hello","text":"World","date":0}"#.utf8)
        let entry = try JSONDecoder().decode(NotificationHistoryEntry.self, from: data)
        #expect(entry.id == "key")
        #expect(entry.phoneID == "key")
        #expect(entry.peer == nil)
        #expect(entry.buttons.isEmpty)
    }

    @Test func actionsAndSourcePhoneSurviveStorage() throws {
        let actions = NotificationAction.parse([["title": ""], ["title": "Approve"], ["title": "Reply", "reply": true]])
        let first = NotificationHistoryEntry(id: "same-key", app: "Messages", pkg: "messages",
                                             title: "Hello", text: "World", date: Date(), peer: "phone-one", actions: actions)
        let second = NotificationHistoryEntry(id: "same-key", app: "Messages", pkg: "messages",
                                              title: "Hello", text: "World", date: Date(), peer: "phone-two", actions: actions)
        let restored = try JSONDecoder().decode(NotificationHistoryEntry.self, from: JSONEncoder().encode(first))
        #expect(restored == first)
        #expect(restored.phoneID == "same-key")
        #expect(restored.peer == "phone-one")
        #expect(restored.id != second.id)
        #expect(restored.buttons.map(\.index) == [1, 2])
        #expect(restored.buttons.map(\.reply) == [false, true])
    }
}
