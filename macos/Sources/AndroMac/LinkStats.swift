import Foundation
import SwiftUI

/// Link counters.
///
/// The project claims "minimum energy consumption" (docs/ENERGY.md). A claim that cannot be
/// measured cannot be verified: this holds the messages-per-hour rate, the reconnect count and the
/// byte volume, and shows them in the macOS Settings tab. When a rule is broken — for example if a
/// timer comes back on the phone — the messages/hour rate jumps.
///
/// The counters live in memory only; they reset when the app quits. Persistence is unnecessary,
/// the point is to answer "what happened in this session".
@MainActor
final class LinkStats: ObservableObject {

    static let shared = LinkStats()

    @Published private(set) var sent = 0
    @Published private(set) var received = 0
    @Published private(set) var bytesSent = 0
    @Published private(set) var bytesReceived = 0
    @Published private(set) var reconnects = 0
    @Published private(set) var connectedSince: Date?

    private let launchedAt = Date()

    /// How many times each message type arrived — shows which feature generates the traffic.
    @Published private(set) var byType: [String: Int] = [:]

    func recordSent(bytes: Int) {
        sent += 1
        bytesSent += bytes
    }

    func recordReceived(_ type: String, bytes: Int) {
        received += 1
        bytesReceived += bytes
        byType[type, default: 0] += 1
    }

    func sessionStarted() {
        if connectedSince != nil { reconnects += 1 }
        connectedSince = Date()
    }

    func sessionEnded() {
        connectedSince = nil
    }

    // MARK: derived measures

    var uptime: TimeInterval { Date().timeIntervalSince(launchedAt) }

    /// The messages-per-hour rate. Per PROTOCOL §6 the expected idle baseline is very low: only the
    /// Mac's 240 s ping (≈15/hour) and the corresponding pongs.
    var messagesPerHour: Double {
        let hours = max(uptime / 3600, 1.0 / 3600)
        return Double(sent + received) / hours
    }

    var totalBytes: Int { bytesSent + bytesReceived }

    func formattedUptime() -> String {
        let total = Int(uptime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0
            ? String(localized: "\(hours) h \(minutes) min")
            : String(localized: "\(minutes) min")
    }

    func formattedBytes() -> String {
        let bytes = Double(totalBytes)
        if bytes < 1024 { return "\(totalBytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", bytes / 1024) }
        return String(format: "%.2f MB", bytes / (1024 * 1024))
    }

    /// The three message types that generate the most traffic.
    var topTypes: [(type: String, count: Int)] {
        byType.sorted { $0.value > $1.value }
            .prefix(3)
            .map { (type: $0.key, count: $0.value) }
    }

    func reset() {
        sent = 0
        received = 0
        bytesSent = 0
        bytesReceived = 0
        reconnects = 0
        byType = [:]
    }
}
