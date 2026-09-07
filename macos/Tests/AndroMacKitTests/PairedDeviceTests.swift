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
        #expect(one.id.count == 8)
        #expect(one.shortFingerprint == "\(one.id.prefix(4)) \(one.id.suffix(4))")
    }

    @Test func survivesAJSONRoundTrip() throws {
        let device = PairedDevice(key: keyA, name: "Pixel 9", lastSeen: Date(timeIntervalSince1970: 1_750_000_000), paused: true)
        let back = try JSONDecoder().decode([PairedDevice].self, from: JSONEncoder().encode([device]))
        #expect(back == [device])
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

    @Test func corruptStoredDataFallsBackToTheLegacyPairing() {
        let (devices, migrated) = PairedDevice.load(
            stored: Data("not json".utf8), legacyKey: keyA, legacyName: "Pixel 9"
        )
        #expect(migrated)
        #expect(devices.map(\.key) == [keyA])
    }
}
