import Foundation

/// The phone's SMS conversations as the Mac reads them off the wire (PROTOCOL §5, Messages).
///
/// Everything here is untrusted input: types are checked, lengths and counts are clamped to what
/// the protocol allows, and an entry that does not make sense is dropped rather than the whole
/// message. Nothing in it is ever written to disk.
public enum SMS {

    /// `body` limit, in UTF-16 units: what Android's `String.length` counts on the other side.
    public static let maxBody = 2048
    public static let maxAddress = 32
    public static let maxThreads = 50
    public static let maxMessages = 200
    public static let maxSnippet = 160
    public static let maxID = 64

    public enum State: String, Sendable {
        case ok, off
        case noPermission = "no_permission"
    }

    public enum Status: String, Sendable {
        case received, sent, pending, failed
    }

    public struct Thread: Equatable, Identifiable, Sendable {
        public let id: Int64
        public let address: String
        public let name: String?
        public let snippet: String
        public let date: Date
        public let unread: Int

        public init(id: Int64, address: String, name: String?, snippet: String, date: Date, unread: Int) {
            self.id = id; self.address = address; self.name = name
            self.snippet = snippet; self.date = date; self.unread = unread
        }

        /// The contact's name when the phone sent one, otherwise the number.
        public var title: String { name ?? address }
    }

    public struct Message: Equatable, Identifiable, Sendable {
        public let id: Int64
        public let body: String
        public let date: Date
        public let outgoing: Bool
        public let status: Status

        public init(id: Int64, body: String, date: Date, outgoing: Bool, status: Status) {
            self.id = id; self.body = body; self.date = date; self.outgoing = outgoing; self.status = status
        }
    }

    public struct Threads: Equatable, Sendable {
        public let state: State
        public let threads: [Thread]

        public init(state: State, threads: [Thread]) { self.state = state; self.threads = threads }
    }

    public struct Messages: Equatable, Sendable {
        public let thread: Int64
        public let state: State
        public let messages: [Message]

        public init(thread: Int64, state: State, messages: [Message]) {
            self.thread = thread; self.state = state; self.messages = messages
        }
    }

    public struct Sent: Equatable, Sendable {
        public let id: String
        public let ok: Bool
        public let reason: String?

        public init(id: String, ok: Bool, reason: String?) { self.id = id; self.ok = ok; self.reason = reason }
    }

    // MARK: parsing

    /// `sms_threads`. Nil when the message itself is unusable (no known `state`).
    public static func threads(_ msg: [String: Any]) -> Threads? {
        guard let state = state(msg["state"]) else { return nil }
        guard state == .ok else { return Threads(state: state, threads: []) }
        let raw = msg["threads"] as? [[String: Any]] ?? []
        var seen = Set<Int64>()
        let threads: [Thread] = raw.prefix(maxThreads).compactMap { entry in
            guard let id = integer(entry["thread"]), seen.insert(id).inserted,
                  let address = text(entry["addr"], 64), !address.isEmpty,
                  let ts = integer(entry["ts"]) else { return nil }
            let name = text(entry["name"], 64).flatMap { $0.isEmpty ? nil : $0 }
            return Thread(id: id, address: address, name: name,
                          snippet: oneLine(text(entry["snippet"], maxSnippet) ?? ""),
                          date: date(ms: ts), unread: max(0, min(Int(integer(entry["unread"]) ?? 0), 9999)))
        }
        return Threads(state: state, threads: threads)
    }

    /// `sms_messages`. Oldest first, as the phone sends them; only the most recent 200 are kept.
    public static func messages(_ msg: [String: Any]) -> Messages? {
        guard let thread = integer(msg["thread"]), let state = state(msg["state"]) else { return nil }
        guard state == .ok else { return Messages(thread: thread, state: state, messages: []) }
        let raw = msg["messages"] as? [[String: Any]] ?? []
        var seen = Set<Int64>()
        let messages: [Message] = raw.suffix(maxMessages).compactMap { entry in
            guard let id = integer(entry["id"]), seen.insert(id).inserted,
                  let body = text(entry["body"], maxBody),
                  let ts = integer(entry["ts"]),
                  let status = (entry["status"] as? String).flatMap(Status.init(rawValue:)) else { return nil }
            return Message(id: id, body: body, date: date(ms: ts),
                           outgoing: entry["out"] as? Bool ?? false, status: status)
        }
        return Messages(thread: thread, state: state, messages: messages)
    }

    /// `sms_sent`. Nil without an id, or an id longer than any the Mac sends.
    public static func sent(_ msg: [String: Any]) -> Sent? {
        guard let id = msg["id"] as? String, !id.isEmpty, id.count <= maxID,
              let ok = msg["ok"] as? Bool else { return nil }
        return Sent(id: id, ok: ok, reason: ok ? nil : (text(msg["reason"], 32) ?? "failed"))
    }

    // MARK: sending

    /// A number the phone accepts in `sms_send`: digits, spaces, `+ - ( )`, at most 32 characters
    /// and at least one digit. An alphanumeric sender ("BANK") cannot be answered.
    public static func isValidAddress(_ address: String) -> Bool {
        guard !address.isEmpty, address.count <= maxAddress else { return false }
        let allowed = Set("0123456789 +-()")
        return address.allSatisfy(allowed.contains) && address.contains(where: \.isNumber)
    }

    /// Trimmed, 1 to 2048 UTF-16 units: what the Send button and the phone both accept.
    public static func sendable(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= maxBody else { return nil }
        return trimmed
    }

    /// The `id` of one `sms_send`: unique enough within one open window, short on the wire.
    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    /// Whether two ways of writing a number reach the same phone: "0555 111 22 33" and
    /// "+905551112233". Compares the last ten digits, or all of them when either is shorter.
    public static func sameNumber(_ a: String, _ b: String) -> Bool {
        let x = a.filter(\.isNumber), y = b.filter(\.isNumber)
        guard !x.isEmpty, !y.isEmpty else { return a.caseInsensitiveCompare(b) == .orderedSame }
        if x.count < 7 || y.count < 7 { return x == y }
        return x.suffix(10) == y.suffix(10)
    }

    // MARK: presentation

    /// A timestamp goes above a bubble when it starts a new day or follows an hour of silence.
    public static func startsGroup(previous: Date?, current: Date, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        return !calendar.isDate(previous, inSameDayAs: current) || current.timeIntervalSince(previous) > 3600
    }

    // MARK: helpers

    private static func state(_ value: Any?) -> State? {
        (value as? String).flatMap(State.init(rawValue:))
    }

    /// A JSON integer. A boolean is not one, although Foundation bridges it as a number.
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9e15 else { return nil }
        return number.int64Value
    }

    private static func text(_ value: Any?, _ limit: Int) -> String? {
        (value as? String).map { String($0.prefix(limit)) }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}
