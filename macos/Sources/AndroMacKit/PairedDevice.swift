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
    /// Last time a session with this device was established. `nil` until it connects once.
    public var lastSeen: Date?
    /// Paused devices stay paired but are not let in. The user's "disconnect and stay disconnected"
    /// — without it, closing a session just makes the phone redial on its backoff ladder.
    public var paused: Bool
    /// Does the Mac's clipboard go to this phone when something is copied here?
    ///
    /// Per device rather than global: with two phones, "sync my clipboard" is a different answer
    /// for the work phone than for the personal one. Incoming clipboards are always accepted —
    /// that is the phone's deliberate act, and refusing it silently would be baffling.
    public var receivesClipboard: Bool

    public init(
        key: Data, name: String, pairedAt: Date = Date(), lastSeen: Date? = nil,
        paused: Bool = false, receivesClipboard: Bool = true
    ) {
        self.key = key
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.paused = paused
        self.receivesClipboard = receivesClipboard
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
    }

    /// Stable, short, and safe to show or log: the first 8 hex characters of SHA-256 over the key.
    /// Used as the dictionary key for live sessions and per-device state.
    public var id: String { Self.fingerprint(of: key) }

    public static func fingerprint(of key: Data) -> String {
        SHA256.hash(data: key).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Grouped in fours, the way a fingerprint is meant to be read aloud: `a1b2 c3d4`.
    public var shortFingerprint: String {
        let id = self.id
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
