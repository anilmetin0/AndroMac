import CryptoKit
import Foundation

/// The on-disk form of the notification and clipboard histories: AES-256-GCM under a key that
/// never touches the disk. Pure, so the one branch that can lose a user's history (reading a
/// file written before encryption) is testable.
public enum SealedFile {

    /// The history key: derived from this Mac's identity key, which lives in the Keychain, so
    /// another program running as the user can read the file but not what is in it.
    public static func key(from identity: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: identity),
            info: Data("AndroMac history v1".utf8),
            outputByteCount: 32
        )
    }

    public static func seal(_ plaintext: Data, key: SymmetricKey) -> Data? {
        try? AES.GCM.seal(plaintext, using: key).combined
    }

    /// The plaintext, or nil when the file is neither ours nor a plain JSON file from before
    /// encryption (the next save rewrites that one sealed).
    public static func open(_ data: Data, key: SymmetricKey) -> Data? {
        if let box = try? AES.GCM.SealedBox(combined: data), let plain = try? AES.GCM.open(box, using: key) {
            return plain
        }
        return data.first == UInt8(ascii: "[") ? data : nil
    }
}
