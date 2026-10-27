import Foundation
import Testing
@testable import AndroMacKit

struct SMSTests {

    /// Through JSONSerialization, as the messages arrive: numbers and booleans as NSNumber.
    private func wire(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    @Test func readsTheConversationList() {
        let parsed = SMS.threads(wire("""
            {"t":"sms_threads","state":"ok","threads":[
              {"thread":42,"addr":"+905551112233","name":"Ayşe","snippet":"Yol\\ndayım","ts":1750000000000,"unread":1},
              {"thread":7,"addr":"BANK","snippet":"Code 1234","ts":1749990000000,"unread":0}]}
            """))
        #expect(parsed?.state == .ok)
        #expect(parsed?.threads.count == 2)
        let first = parsed?.threads.first
        #expect(first?.title == "Ayşe")
        #expect(first?.snippet == "Yol dayım")
        #expect(first?.date == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(first?.unread == 1)
        #expect(parsed?.threads.last?.title == "BANK")
    }

    @Test func dropsMalformedEntriesAndClamps() {
        let long = String(repeating: "a", count: 500)
        let parsed = SMS.threads(wire("""
            {"state":"ok","threads":[
              {"thread":true,"addr":"1","ts":1},
              {"thread":1.5,"addr":"1","ts":1},
              {"thread":1,"ts":1},
              {"thread":2,"addr":"","ts":1},
              {"thread":3,"addr":"5","ts":"x"},
              {"thread":4,"addr":"5","ts":1,"snippet":"\(long)","unread":-3},
              {"thread":4,"addr":"6","ts":1}]}
            """))
        #expect(parsed?.threads.map(\.id) == [4])
        #expect(parsed?.threads.first?.snippet.count == SMS.maxSnippet)
        #expect(parsed?.threads.first?.unread == 0)
    }

    @Test func keepsAtMostFiftyThreadsAndTwoHundredMessages() {
        let threads = (0..<80).map { ["thread": $0, "addr": "5", "ts": 1] as [String: Any] }
        #expect(SMS.threads(["state": "ok", "threads": threads])?.threads.count == SMS.maxThreads)
        let messages = (0..<300).map { ["id": $0, "body": "x", "ts": 1, "status": "sent"] as [String: Any] }
        let parsed = SMS.messages(["thread": 1, "state": "ok", "messages": messages])
        #expect(parsed?.messages.count == SMS.maxMessages)
        // The most recent ones: the list is oldest first.
        #expect(parsed?.messages.first?.id == 100)
    }

    @Test func statesOtherThanOkCarryNoData() {
        #expect(SMS.threads(wire(#"{"state":"off","threads":[{"thread":1,"addr":"5","ts":1}]}"#))
            == SMS.Threads(state: .off, threads: []))
        #expect(SMS.threads(wire(#"{"state":"no_permission"}"#))?.state == .noPermission)
        #expect(SMS.threads(wire(#"{"state":"maybe"}"#)) == nil)
        #expect(SMS.messages(wire(#"{"thread":3,"state":"off"}"#))?.thread == 3)
        #expect(SMS.messages(wire(#"{"state":"ok"}"#)) == nil)
    }

    @Test func readsMessages() {
        let body = String(repeating: "b", count: 3000)
        let parsed = SMS.messages(wire("""
            {"thread":42,"state":"ok","messages":[
              {"id":901,"body":"Yoldayım","ts":1750000000000,"out":false,"status":"received"},
              {"id":902,"body":"\(body)","ts":1750000060000,"out":true,"status":"failed"},
              {"id":903,"body":"x","ts":1,"out":true,"status":"delivered"}]}
            """))
        #expect(parsed?.messages.count == 2)
        #expect(parsed?.messages.first?.outgoing == false)
        #expect(parsed?.messages.last?.body.count == SMS.maxBody)
        #expect(parsed?.messages.last?.status == .failed)
    }

    @Test func readsTheSendResult() {
        #expect(SMS.sent(wire(#"{"id":"7c1e","ok":true}"#)) == SMS.Sent(id: "7c1e", ok: true, reason: nil))
        #expect(SMS.sent(wire(#"{"id":"7c1e","ok":false,"reason":"no_service"}"#))?.reason == "no_service")
        #expect(SMS.sent(wire(#"{"id":"7c1e","ok":false}"#))?.reason == "failed")
        #expect(SMS.sent(wire(#"{"ok":true}"#)) == nil)
        #expect(SMS.sent(["id": String(repeating: "a", count: 65), "ok": true]) == nil)
    }

    @Test func validatesWhatGoesOut() {
        #expect(SMS.isValidAddress("+90 (555) 111-22-33"))
        #expect(!SMS.isValidAddress("BANK"))
        #expect(!SMS.isValidAddress("+-()"))
        #expect(!SMS.isValidAddress(String(repeating: "1", count: 33)))
        #expect(!SMS.isValidAddress("555;1"))

        #expect(SMS.sendable("  hi\n") == "hi")
        #expect(SMS.sendable(" \n ") == nil)
        #expect(SMS.sendable(String(repeating: "a", count: 2048)) != nil)
        #expect(SMS.sendable(String(repeating: "a", count: 2049)) == nil)
        // Counted as the phone counts: an emoji is two UTF-16 units.
        #expect(SMS.sendable(String(repeating: "😀", count: 1025)) == nil)

        let id = SMS.newID()
        #expect(!id.isEmpty && id.count <= SMS.maxID && id != SMS.newID())
    }

    @Test func matchesNumbersWrittenDifferently() {
        #expect(SMS.sameNumber("0555 111 22 33", "+905551112233"))
        #expect(SMS.sameNumber("4636", "4636"))
        #expect(!SMS.sameNumber("4636", "14636"))
        #expect(!SMS.sameNumber("+905551112233", "+905551112234"))
    }

    @Test func groupsTimestamps() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: TimeInterval(1_750_000_000 - 1_750_000_000 % 86400 + 43200))
        #expect(SMS.startsGroup(previous: nil, current: noon, calendar: calendar))
        #expect(!SMS.startsGroup(previous: noon, current: noon + 1800, calendar: calendar))
        #expect(SMS.startsGroup(previous: noon, current: noon + 3700, calendar: calendar))
        #expect(SMS.startsGroup(previous: noon + 43000, current: noon + 43300, calendar: calendar))
    }
}
