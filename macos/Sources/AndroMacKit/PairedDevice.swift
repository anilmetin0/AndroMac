import CryptoKit
import Foundation

/// One phone the user has trusted, as it is written to disk.
///
/// **The static public key is the identity.** Not the name, not the IP, not the Bonjour instance —
/// those all change or can be spoofed. This is the same choice Syncthing makes (device ID = a hash
/// of the certificate) and KDE Connect makes (the device ID is the certificate's Common Name, and
/// it aborts the handshake if the two ever disagree). It falls out of the handshake for free: by
/// the time we have a peer's static key, that peer has proven it holds the matching private key
/// (PROTOCOL §2), so a key we recognise is a device we have met.
///
/// A consequence worth stating plainly: if a phone is wiped and reinstalled it generates a new
/// identity key, so it arrives as a *new* device and has to be paired again. That is the correct
/// and safe outcome — the alternative would be trusting a key we have never seen because it
/// claimed a familiar name.
public struct PairedDevice: Codable, Identifiable, Sendable, Equatable {

    /// The peer's static public key, X9.62 uncompressed, exactly as pinned during pairing.
    public let key: Data
    /// What the phone called itself in `hello`, or what the user renamed it to. Display only.
    public var name: String
    public let pairedAt: Date
    /// Last time a session with this device started or ended. `nil` until it connects once.
    public var lastSeen: Date?
    /// The phone's LAN IPv4 on its last connection, so two phones can be told apart. Display only:
    /// DHCP hands it to someone else tomorrow, and it says nothing about who is calling.
    public var lastAddress: String?
    /// Auto-connect off for this phone: it stays paired but is let in only when someone taps Connect
    /// there (PROTOCOL §3). The user's "disconnect and stay disconnected" — without it, closing a
    /// session just makes the phone redial on its backoff ladder.
    public var paused: Bool
    /// When `paused` last changed, here or on the phone: the auto-connect switch is one setting on
    /// both sides, and the newer change wins (PROTOCOL §3). `nil` until it is first changed.
    public var autoConnectChanged: Date?
    /// Does the Mac's clipboard go to this phone when something is copied here?
    ///
    /// Per device rather than global: with two phones, "sync my clipboard" is a different answer
    /// for the work phone than for the personal one. Incoming clipboards are always accepted —
    /// that is the phone's deliberate act, and refusing it silently would be baffling.
    public var receivesClipboard: Bool

    public init(
        key: Data, name: String, pairedAt: Date = Date(), lastSeen: Date? = nil,
        paused: Bool = false, receivesClipboard: Bool = true, lastAddress: String? = nil
    ) {
        self.key = key
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.paused = paused
        self.receivesClipboard = receivesClipboard
        self.lastAddress = lastAddress
    }

    /// Decoded by hand so that a device written by an older build still loads.
    ///
    /// Swift's synthesized decoder treats every stored property as required — a default value in
    /// the declaration does NOT make a missing key acceptable. So the moment a new per-device
    /// setting is added, every device saved before it becomes undecodable, `load` falls through to
    /// its "corrupt" path, and the user silently loses their pairings. Reading the optional fields
    /// with `decodeIfPresent` costs a few lines and makes adding the next flag a non-event.
    /// `key` and `pairedAt` are required on purpose: a device record without them is meaningless.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(Data.self, forKey: .key)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        pairedAt = try c.decode(Date.self, forKey: .pairedAt)
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        receivesClipboard = try c.decodeIfPresent(Bool.self, forKey: .receivesClipboard) ?? true
        lastAddress = try c.decodeIfPresent(String.self, forKey: .lastAddress)
        autoConnectChanged = try c.decodeIfPresent(Date.self, forKey: .autoConnectChanged)
    }

    /// What to do with the phone's auto-connect switch against this Mac's (PROTOCOL §3).
    public enum AutoConnectSync: Equatable, Sendable {
        /// The phone's change is newer: take its value.
        case adopt
        /// Ours is newer and they differ: tell the phone.
        case tell
        case keep
    }

    /// Last writer wins, and with neither change newer, off wins: both sides start on, so an off
    /// nobody dated (a phone's switch from before it was dated) was still turned off on purpose.
    /// The phone applies the same rule to the Mac's switch, so the two cannot settle apart.
    // ponytail: wall clocks of two devices, both set from the network; seconds of skew only matter
    // for two flips seconds apart on both sides. A clock set by hand minutes off widens that window
    // as far; a shared change counter instead of times would close it.
    public func syncAutoConnect(phoneOn: Bool, changed phoneChanged: Date?) -> AutoConnectSync {
        guard phoneOn == paused else { return .keep }       // the same value on both sides
        let phone = phoneChanged ?? .distantPast, mac = autoConnectChanged ?? .distantPast
        if phone != mac { return phone > mac ? .adopt : .tell }
        return phoneOn ? .tell : .adopt
    }

    /// Auto-connect was turned on here after the phone was last seen. The phone's own switch is
    /// still off as far as this Mac knows, so it stays parked until someone taps Connect there.
    public var awaitsConnectOnPhone: Bool {
        guard !paused, let changed = autoConnectChanged else { return false }
        return changed > (lastSeen ?? .distantPast)
    }

    /// Dates every pause written before the switch was dated (1.5.1) to `now`, once. The phone's
    /// switch never touched it until then, so no change made there earlier may undo it.
    /// - Returns: whether any was dated, so the caller writes the list back.
    public static func dateUndatedPauses(_ devices: inout [PairedDevice], now: Date) -> Bool {
        var dated = false
        for i in devices.indices where devices[i].paused && devices[i].autoConnectChanged == nil {
            devices[i].autoConnectChanged = now
            dated = true
        }
        return dated
    }

    /// The full SHA-256 of the key, in hex. The dictionary key for live sessions and per-device
    /// state. Never the short fingerprint: 32 bits can be ground in hours, and two keys sharing an
    /// id would share a session slot and every per-device setting.
    public var id: String { Self.id(of: key) }

    public static func id(of key: Data) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    /// Short and safe to show or log: the first 8 hex characters of the id. Display only.
    public static func fingerprint(of key: Data) -> String { String(id(of: key).prefix(8)) }

    /// Grouped in fours, the way a fingerprint is meant to be read aloud: `a1b2 c3d4`.
    public var shortFingerprint: String {
        let id = Self.fingerprint(of: key)
        return stride(from: 0, to: id.count, by: 4)
            .map { String(id.dropFirst($0).prefix(4)) }
            .joined(separator: " ")
    }

    /// Decide what the device list is, given what is on disk.
    ///
    /// Split out from `Store` so the one branch that can lose a user's pairing is testable without
    /// touching UserDefaults. Order matters: the new format wins whenever it parses, so a stale
    /// legacy key left behind by an interrupted migration can never resurrect a device the user has
    /// since removed.
    ///
    /// - Parameters:
    ///   - stored: the JSON written by a previous run, if any.
    ///   - legacyKey: the v1 `peerKey` default — one paired phone, or `nil`.
    ///   - legacyName: the v1 `peerName` default.
    /// - Returns: the device list, and whether it came from a migration (the caller then persists
    ///   it and drops the legacy keys).
    public static func load(
        stored: Data?, legacyKey: Data?, legacyName: String
    ) -> (devices: [PairedDevice], migrated: Bool) {
        if let stored, let devices = try? JSONDecoder().decode([PairedDevice].self, from: stored) {
            return (devices, false)
        }
        guard let legacyKey else { return ([], false) }
        // `pairedAt` is genuinely unknown for a migrated pairing; `.distantPast` sorts it oldest,
        // which is the one thing we do know about it.
        return ([PairedDevice(key: legacyKey, name: legacyName, pairedAt: .distantPast)], true)
    }
}
