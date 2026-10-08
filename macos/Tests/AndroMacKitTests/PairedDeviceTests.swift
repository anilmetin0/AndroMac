import Foundation
import Testing
@testable import AndroMacKit

struct PairedDeviceTests {

    private let keyA = Data(repeating: 0xA1, count: 65)
    private let keyB = Data(repeating: 0xB2, count: 65)

    // MARK: identity

    @Test func fingerprintFollowsTheKeyAndNothingElse() {
        let one = PairedDevice(key: keyA, name: "Pixel 9")
        let renamed = PairedDevice(key: keyA, name: "Something else")
        let other = PairedDevice(key: keyB, name: "Pixel 9")

        #expect(one.id == renamed.id)      // the name is decoration, the key is the identity
        #expect(one.id != other.id)
        #expect(one.id.count == 64)        // the full hash: a 32-bit id could be ground
        let short = PairedDevice.fingerprint(of: keyA)
        #expect(short == String(one.id.prefix(8)))
        #expect(one.shortFingerprint == "\(short.prefix(4)) \(short.suffix(4))")
    }

    @Test func survivesAJSONRoundTrip() throws {
        let device = PairedDevice(key: keyA, name: "Pixel 9", lastSeen: Date(timeIntervalSince1970: 1_750_000_000), paused: true,
                                  lastAddress: "192.168.1.42")
        let back = try JSONDecoder().decode([PairedDevice].self, from: JSONEncoder().encode([device]))
        #expect(back == [device])
    }

    // MARK: auto-connect, one switch on both sides

    @Test func theNewerAutoConnectChangeWins() {
        let t1 = Date(timeIntervalSince1970: 1_750_000_000), t2 = t1.addingTimeInterval(60)
        var mac = PairedDevice(key: keyA, name: "Pixel 9", paused: true)
        mac.autoConnectChanged = t1
        #expect(mac.syncAutoConnect(phoneOn: true, changed: t2) == .adopt)    // turned on there later
        #expect(mac.syncAutoConnect(phoneOn: true, changed: t1.addingTimeInterval(-60)) == .tell)
        #expect(mac.syncAutoConnect(phoneOn: true, changed: nil) == .tell)    // never touched there
        #expect(mac.syncAutoConnect(phoneOn: false, changed: t2) == .keep)    // already agree
    }

    @Test func withNeitherChangeNewerOffWins() {
        // A phone's switch turned off before it was dated, against a Mac never touched: the two
        // must settle on one value rather than stay apart for good.
        let mac = PairedDevice(key: keyA, name: "Pixel 9")
        #expect(mac.syncAutoConnect(phoneOn: false, changed: nil) == .adopt)
        let paused = PairedDevice(key: keyA, name: "Pixel 9", paused: true)
        #expect(paused.syncAutoConnect(phoneOn: true, changed: nil) == .tell)
    }

    @Test func aPauseFromBeforeTheSwitchWasDatedOutranksEarlierPhoneChanges() {
        let upgrade = Date(timeIntervalSince1970: 1_760_000_000)
        var devices = [PairedDevice(key: keyA, name: "Pixel 9", paused: true),
                       PairedDevice(key: keyB, name: "Pixel 8")]
        #expect(PairedDevice.dateUndatedPauses(&devices, now: upgrade))
        #expect(devices[0].autoConnectChanged == upgrade)
        #expect(devices[1].autoConnectChanged == nil)                       // only pauses are dated
        #expect(devices[0].syncAutoConnect(phoneOn: true, changed: upgrade.addingTimeInterval(-3600)) == .tell)
        #expect(!PairedDevice.dateUndatedPauses(&devices, now: upgrade))    // once
    }

    @Test func turnedOnHereWhileThePhoneWasAwayItStillNeedsATapThere() {
        let seen = Date(timeIntervalSince1970: 1_750_000_000)
        var mac = PairedDevice(key: keyA, name: "Pixel 9", lastSeen: seen)
        #expect(!mac.awaitsConnectOnPhone)                                   // never changed
        mac.autoConnectChanged = seen.addingTimeInterval(60)
        #expect(mac.awaitsConnectOnPhone)
        mac.lastSeen = seen.addingTimeInterval(120)                          // it has been here since
        #expect(!mac.awaitsConnectOnPhone)
        mac.paused = true
        mac.autoConnectChanged = seen.addingTimeInterval(180)
        #expect(!mac.awaitsConnectOnPhone)                                   // off: nothing to wait for
    }

    // MARK: the migration that can lose a pairing

    @Test func firstRunWithNothingStoredHasNoDevices() {
        let (devices, migrated) = PairedDevice.load(stored: nil, legacyKey: nil, legacyName: "")
        #expect(devices.isEmpty)
        #expect(!migrated)
    }

    @Test func upgradingFromASinglePairingKeepsIt() throws {
        let (devices, migrated) = PairedDevice.load(stored: nil, legacyKey: keyA, legacyName: "Pixel 9")
        #expect(migrated)
        #expect(devices.count == 1)
        #expect(devices[0].key == keyA)
        #expect(devices[0].name == "Pixel 9")
        #expect(devices[0].pairedAt == .distantPast)
        #expect(!devices[0].paused)
    }

    @Test func storedListWinsOverALeftoverLegacyKey() throws {
        // An interrupted migration can leave both behind. Trusting the legacy key here would bring
        // back a phone the user had already removed.
        let stored = try JSONEncoder().encode([PairedDevice(key: keyB, name: "Pixel 8")])
        let (devices, migrated) = PairedDevice.load(stored: stored, legacyKey: keyA, legacyName: "Pixel 9")
        #expect(!migrated)
        #expect(devices.map(\.key) == [keyB])
    }

    @Test func anEmptyStoredListIsNotMistakenForAMissingOne() throws {
        // The user unpaired everything. That is a real answer, not an absent one — re-migrating
        // would silently re-pair the old phone.
        let stored = try JSONEncoder().encode([PairedDevice]())
        let (devices, migrated) = PairedDevice.load(stored: stored, legacyKey: keyA, legacyName: "Pixel 9")
        #expect(devices.isEmpty)
        #expect(!migrated)
    }

    /// The bug this prevents: Swift's synthesized decoder treats every stored property as required,
    /// so adding one per-device flag would make every previously saved device undecodable, `load`
    /// would take its "corrupt" branch, and the user would lose their pairings on upgrade.
    @Test func aDeviceSavedBeforeTheNewerFlagsExistedStillLoads() throws {
        let old = """
        [{"key":"\(keyA.base64EncodedString())","name":"Pixel 9","pairedAt":0}]
        """
        let devices = try JSONDecoder().decode([PairedDevice].self, from: Data(old.utf8))
        #expect(devices.count == 1)
        #expect(devices[0].name == "Pixel 9")
        #expect(!devices[0].paused)                 // absent flags fall back to their defaults
        #expect(devices[0].receivesClipboard)       // and clipboard sync defaults to on
        #expect(devices[0].lastSeen == nil)
    }

    @Test func aDeviceSavedBeforeLastAddressStillLoads() throws {
        let old = """
        [{"key":"\(keyA.base64EncodedString())","name":"Pixel 9","pairedAt":0,"lastSeen":10,"paused":true}]
        """
        let devices = try JSONDecoder().decode([PairedDevice].self, from: Data(old.utf8))
        #expect(devices.count == 1)
        #expect(devices[0].lastAddress == nil)
        #expect(devices[0].lastSeen == Date(timeIntervalSinceReferenceDate: 10))
        #expect(devices[0].paused)
    }

    @Test func corruptStoredDataFallsBackToTheLegacyPairing() {
        let (devices, migrated) = PairedDevice.load(
            stored: Data("not json".utf8), legacyKey: keyA, legacyName: "Pixel 9"
        )
        #expect(migrated)
        #expect(devices.map(\.key) == [keyA])
    }
}
