import CryptoKit
import Foundation

/// P-256 ECDH + HKDF-SHA256 + AES-256-GCM. docs/PROTOCOL.md §2 and §4.
/// Must stay byte-for-byte compatible with `Crypto.kt` on the Android side.
public enum Crypto {

    public static let pubLen = 65      // X9.62 uncompressed

    // MARK: keys

    public static func generateKeyPair() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    public static func encodePublic(_ key: P256.KeyAgreement.PublicKey) -> Data {
        key.x963Representation                       // 0x04 || X(32) || Y(32)
    }

    /// Points that are not on the curve are rejected here (CryptoKit validates them).
    public static func decodePublic(_ bytes: Data) throws -> P256.KeyAgreement.PublicKey {
        guard bytes.count == pubLen else { throw WireError.protocolError("invalid public key length") }
        return try P256.KeyAgreement.PublicKey(x963Representation: bytes)
    }

    public static func ecdh(_ own: P256.KeyAgreement.PrivateKey, _ peer: P256.KeyAgreement.PublicKey) throws -> Data {
        let secret = try own.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }

    // MARK: KDF

    public static func sha256(_ parts: Data...) -> Data {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }

    /// RFC 5869. Produces the same result as the hand-written HKDF on Android.
    public static func hkdf(salt: Data, ikm: Data, info: String, count: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: count
        )
    }

    // MARK: AEAD

    /// 12 bytes: 4 zero bytes + a big-endian 64-bit counter.
    public static func nonce(_ counter: UInt64) throws -> AES.GCM.Nonce {
        var raw = Data(count: 4)
        raw.append(contentsOf: withUnsafeBytes(of: counter.bigEndian) { Data($0) })
        return try AES.GCM.Nonce(data: raw)
    }

    /// CAUTION: the output of Java's `Cipher.doFinal` is `ciphertext || tag`; it carries no nonce.
    /// That is why CryptoKit's `.combined` field (which also contains the nonce) is NOT USED.
    public static func seal(_ key: SymmetricKey, _ counter: UInt64, _ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: try nonce(counter))
        return box.ciphertext + box.tag
    }

    public static func open(_ key: SymmetricKey, _ counter: UInt64, _ payload: Data) throws -> Data {
        guard payload.count > 16 else { throw WireError.protocolError("frame too short") }
        let box = try AES.GCM.SealedBox(
            nonce: try nonce(counter),
            ciphertext: payload.prefix(payload.count - 16),
            tag: payload.suffix(16)
        )
        return try AES.GCM.open(box, using: key)
    }

    // MARK: SAS

    public static let nonceLen = 32      // n_A / n_B and the commitment c_B, PROTOCOL §2
    public static let tagLen = 16        // AES-GCM tag, appended to every ciphertext

    public static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    /// docs/PROTOCOL.md §2 — c_B = SHA256("AndroMac/commit" || n_B).
    public static func commit(_ nonce: Data) -> Data {
        sha256(Data("AndroMac/commit".utf8), nonce)
    }

    /// docs/PROTOCOL.md §3 — the 6 digits compared on the two screens. Bound to the session
    /// transcript and both fresh nonces, so a MITM cannot grind the code offline.
    public static func sas(transcript: Data, nA: Data, nB: Data) -> String {
        let h = sha256(Data("AndroMac/SAS/v3".utf8), transcript, nA, nB)
        let v = h.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return String(format: "%06d", v % 1_000_000)
    }

    /// Constant-time comparison.
    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

public enum WireError: LocalizedError {
    case protocolError(String)
    /// The peer authenticated itself, but its static key is not one we have pinned.
    /// `isFirstDevice` is true when nothing is paired yet — the difference between "set this up"
    /// and "add another phone", which is wording, not security. The SAS is what the user checks.
    case untrusted(peerKey: Data, peerName: String, sas: String, isFirstDevice: Bool)
    case closed

    public var errorDescription: String? {
        switch self {
        case .protocolError(let m): return m
        case .untrusted(_, _, let sas, let mismatch):
            return mismatch ? "the pinned key has changed" : "device is not paired (code \(sas))"
        case .closed: return "connection closed"
        }
    }
}
