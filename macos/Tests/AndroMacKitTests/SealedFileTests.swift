import CryptoKit
import Foundation
import Testing
@testable import AndroMacKit

struct SealedFileTests {

    private let key = SealedFile.key(from: Data(repeating: 7, count: 32))

    @Test func roundTripsAndHidesTheContent() throws {
        let plain = Data(#"[{"text":"481902"}]"#.utf8)
        let sealed = try #require(SealedFile.seal(plain, key: key))
        #expect(!String(decoding: sealed, as: UTF8.self).contains("481902"))
        #expect(SealedFile.open(sealed, key: key) == plain)
    }

    @Test func readsAPlainFileFromBeforeEncryption() {
        let legacy = Data(#"[{"text":"hi"}]"#.utf8)
        #expect(SealedFile.open(legacy, key: key) == legacy)
    }

    @Test func refusesAnotherKeyAndGarbage() throws {
        let sealed = try #require(SealedFile.seal(Data("[]".utf8), key: key))
        let other = SealedFile.key(from: Data(repeating: 8, count: 32))
        #expect(SealedFile.open(sealed, key: other) == nil)
        #expect(SealedFile.open(Data([1, 2, 3]), key: key) == nil)
    }
}

struct SealedPictureTests {
    @Test func picturesOpenOnlySealedAndOnlyWithTheirKey() throws {
        let key = SealedFile.key(from: Data(repeating: 7, count: 32))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 1, count: 100)
        let sealed = try #require(SealedFile.seal(jpeg, key: key))
        #expect(sealed != jpeg)
        #expect(SealedFile.openSealed(sealed, key: key) == jpeg)
        #expect(SealedFile.openSealed(sealed, key: SealedFile.key(from: Data(repeating: 8, count: 32))) == nil)
        #expect(SealedFile.openSealed(jpeg, key: key) == nil)       // an unsealed file is not read
    }
}
