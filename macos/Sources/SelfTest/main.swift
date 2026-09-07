import AndroMacKit
import CryptoKit
import Foundation

// Crypto conformance vectors. The `:vectors` module on the Kotlin side must produce EXACTLY
// the same lines; `verify-crypto.sh` diffs the two. This is the only proof that the two
// independent crypto implementations match byte for byte — if they do not, the handshake
// fails silently on device.

setvbuf(stdout, nil, _IONBF, 0)   // no buffering: output must survive even a crash

// `andromac-selftest handshake <port>` — end-to-end handshake responder
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "handshake",
   let port = UInt16(CommandLine.arguments[2]) {
    runHandshakeResponder(port: port)
    exit(0)
}

func line(_ name: String, _ data: Data) {
    print("\(name)=\(data.map { String(format: "%02x", $0) }.joined())")
}

// Fixed scalars — no randomness, so the output is deterministic.
let sk1 = Data(repeating: 0x11, count: 32)
let sk2 = Data(repeating: 0x22, count: 32)

let k1 = try! P256.KeyAgreement.PrivateKey(rawRepresentation: sk1)
let k2 = try! P256.KeyAgreement.PrivateKey(rawRepresentation: sk2)
let pub1 = Crypto.encodePublic(k1.publicKey)
let pub2 = Crypto.encodePublic(k2.publicKey)

line("pub1", pub1)
line("pub2", pub2)

// ECDH symmetry + equality across platforms
line("ecdh12", try! Crypto.ecdh(k1, Crypto.decodePublic(pub2)))
line("ecdh21", try! Crypto.ecdh(k2, Crypto.decodePublic(pub1)))

// HKDF (RFC 5869)
let salt = Crypto.sha256(Data("salt".utf8))
let ikm = Data((0..<96).map { UInt8($0) })
line("hkdf_a2b", Crypto.hkdf(salt: salt, ikm: ikm, info: "AndroMac a2b", count: 32)
    .withUnsafeBytes { Data($0) })
line("hkdf_b2a", Crypto.hkdf(salt: salt, ikm: ikm, info: "AndroMac b2a", count: 32)
    .withUnsafeBytes { Data($0) })

// Nonce layout: 4 zero bytes + BE64
line("nonce0", try! Crypto.nonce(0).withUnsafeBytes { Data($0) })
line("nonce_big", try! Crypto.nonce(1_234_567_890).withUnsafeBytes { Data($0) })

// AES-256-GCM: the output must be ciphertext||tag (Java compatibility), NOT CryptoKit's .combined
let key = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
let sealed = try! Crypto.seal(key, 7, Data("merhaba dünya".utf8))
line("gcm_seal", sealed)
line("gcm_open", try! Crypto.open(key, 7, sealed))

// Transcript, nonce commitment and SAS (PROTOCOL §2/§3)
let a = Data((0..<65).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
let b = Data((0..<65).map { UInt8(truncatingIfNeeded: $0 * 11 + 5) })
let fixedTranscript = Data(repeating: 0x01, count: 32)
let nA = Data(repeating: 0x02, count: 32)
let nB = Data(repeating: 0x03, count: 32)
line("transcript", Crypto.sha256(Data("AndroMac/v3".utf8), a, b, b, a, Crypto.commit(nB)))
line("commit", Crypto.commit(nB))
print("sas=\(Crypto.sas(transcript: fixedTranscript, nA: nA, nB: nB))")
