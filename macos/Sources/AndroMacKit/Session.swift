import CryptoKit
import Foundation
import Network

/// An encrypted session over an established connection. macOS is always the responder (role B).
public actor Session {

    private let wire: Wire
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private var sendCounter: UInt64 = 1      // 0 was spent on the verification round
    private var recvCounter: UInt64 = 1

    public nonisolated let peerStaticPub: Data
    public nonisolated let sas: String

    private init(wire: Wire, sendKey: SymmetricKey, recvKey: SymmetricKey, peerStaticPub: Data, sas: String) {
        self.wire = wire
        self.sendKey = sendKey
        self.recvKey = recvKey
        self.peerStaticPub = peerStaticPub
        self.sas = sas
    }

    /// Returns the plaintext size in bytes (for the traffic counters; the content is never logged).
    @discardableResult
    public func send(_ message: [String: Any]) async throws -> Int {
        try await send(json: JSONSerialization.data(
            withJSONObject: message, options: [.withoutEscapingSlashes]
        ))
    }

    /// Send a body that is already JSON.
    ///
    /// This is what lets the Mac broadcast to several phones: the message is encoded once and then
    /// sealed once per session, because each session has its own key and its own counter. Handing
    /// the same `[String: Any]` to N sessions instead would be both wasteful and, since `Any` can
    /// hold a reference, something the compiler is right to refuse.
    public func send(json: Data) async throws -> Int {
        let ct = try Crypto.seal(sendKey, sendCounter, json)
        sendCounter &+= 1
        try await wire.writeFrame(ct)
        return json.count
    }

    public func receive() async throws -> sending [String: Any] {
        try await receiveCounted().message
    }

    /// Like `receive()`, plus the plaintext size in bytes.
    public func receiveCounted() async throws -> sending (message: [String: Any], bytes: Int) {
        let ct = try await wire.readFrame()
        let pt = try Crypto.open(recvKey, recvCounter, ct)
        recvCounter &+= 1
        guard let obj = try JSONSerialization.jsonObject(with: pt) as? [String: Any] else {
            throw WireError.protocolError("expected a JSON object")
        }
        return (obj, pt.count)
    }

    public func close() async { await wire.close() }

    // MARK: handshake (role B)

    /// Handshake version byte (docs/PROTOCOL.md §2).
    static let proto: UInt8 = 3
    static let label = Data("AndroMac/v3".utf8)

    /// docs/PROTOCOL.md §2. If the peer's static key is not among `pinnedKeys`, throws
    /// `WireError.untrusted` and the connection is closed — the caller can then show the SAS to the
    /// user and pin it.
    ///
    /// The Mac trusts a *set* of phones, so this is a membership test rather than one comparison.
    /// Note what that changes: there is no longer such a thing as "the pinned key has changed".
    /// A key we do not know is simply a device we have not met, whether it is a new phone or a
    /// phone that was wiped and reinstalled — and either way the only safe answer is the same, a
    /// fresh SAS comparison. What protects the user is the approval, never the label on it.
    public static func accept(
        connection: NWConnection,
        queue: DispatchQueue,
        staticKey: P256.KeyAgreement.PrivateKey,
        peerName: String,
        pinnedKeys: [Data]
    ) async throws -> Session {
        let wire = Wire(connection)

        do {
            // A connection that never reaches .ready must be closed too: when start() sat
            // OUTSIDE the do block, an error left the NWConnection open.
            try await wire.start(on: queue)

            // 1. A -> B — the phone's ephemeral key only; its static key arrives in message 3,
            //    encrypted so that only the holder of our static private key can read it.
            let head = try await wire.receive(exactly: 1 + Crypto.pubLen)
            guard head[head.startIndex] == Self.proto else {
                throw WireError.protocolError("unsupported protocol version: \(head[head.startIndex])")
            }
            let ePubA = Data(head.suffix(Crypto.pubLen))
            let peerEph = try Crypto.decodePublic(ePubA)

            // 2. B -> A — e_B in the clear; s_B and the commitment c_B under the ephemeral-
            //    ephemeral secret. Commit to n_B before A reveals n_A, so neither side can
            //    steer the SAS.
            let sPubBData = Crypto.encodePublic(staticKey.publicKey)
            let eph = Crypto.generateKeyPair()
            let ePubBData = Crypto.encodePublic(eph.publicKey)
            let nB = Crypto.randomBytes(Crypto.nonceLen)
            let cB = Crypto.commit(nB)
            let h1 = Crypto.sha256(Self.label, ePubA, ePubBData)
            // CAUTION: the DH names are written from the initiator's (A) point of view; on B the
            // peer roles are reversed.
            //   dh1 = ECDH(e_A, e_B)  ->  here ECDH(e_B, e_A)
            //   dh2 = ECDH(s_A, e_B)  ->  here ECDH(e_B, s_A)
            //   dh3 = ECDH(e_A, s_B)  ->  here ECDH(s_B, e_A)
            let dh1 = try Crypto.ecdh(eph, peerEph)              // forward secrecy
            let dh3 = try Crypto.ecdh(staticKey, peerEph)        // B's identity
            let ctB = try Crypto.seal(Crypto.hkdf(salt: h1, ikm: dh1, info: "AndroMac/v3 ee", count: 32), 0, sPubBData + cB)
            try await wire.send(Data([Self.proto]) + ePubBData + ctB)

            // 3. A -> B — s_A, readable only with dh3. A phone that pinned a different key
            //    hangs up instead of sending this.
            let ctA = try await wire.receive(exactly: Crypto.pubLen + Crypto.tagLen)
            let sPubA: Data
            do {
                sPubA = try Crypto.open(Crypto.hkdf(salt: h1, ikm: dh1 + dh3, info: "AndroMac/v3 es", count: 32), 0, ctA)
            } catch {
                throw WireError.protocolError("message 3 failed to open — no key agreement, or a MITM")
            }
            let peerStatic = try Crypto.decodePublic(sPubA)

            let transcript = Crypto.sha256(Self.label, ePubA, ePubBData, ctB, ctA)
            let ikm = dh1
                + (try Crypto.ecdh(eph, peerStatic))             // dh2: A's identity
                + dh3

            let kA2B = Crypto.hkdf(salt: transcript, ikm: ikm, info: "AndroMac a2b", count: 32)
            let kB2A = Crypto.hkdf(salt: transcript, ikm: ikm, info: "AndroMac b2a", count: 32)

            // 3b. A -> B verification (transcript || n_A), 4. B -> A verification (transcript || n_B)
            let theirs: Data
            do {
                theirs = try Crypto.open(kA2B, 0, try await wire.readFrame())
            } catch {
                throw WireError.protocolError("verification round failed — no key agreement, or a MITM")
            }
            guard theirs.count == transcript.count + Crypto.nonceLen,
                  Crypto.constantTimeEquals(theirs.prefix(transcript.count), transcript) else {
                throw WireError.protocolError("transcript mismatch — MITM suspected")
            }
            let nA = Data(theirs.suffix(Crypto.nonceLen))
            try await wire.writeFrame(try Crypto.seal(kB2A, 0, transcript + nB))

            // From here on the peer has proven that it holds the s_A private key.
            let sas = Crypto.sas(transcript: transcript, nA: nA, nB: nB)
            // No early exit: every pinned key is compared, so the loop takes the same time whether
            // the match is the first entry or the last. The keys are public, so this is hygiene
            // rather than a defence, and it is cheap enough to keep.
            var trusted = false
            for pinned in pinnedKeys where Crypto.constantTimeEquals(pinned, sPubA) { trusted = true }
            guard trusted else {
                throw WireError.untrusted(
                    peerKey: sPubA, peerName: peerName, sas: sas, isFirstDevice: pinnedKeys.isEmpty
                )
            }

            return Session(wire: wire, sendKey: kB2A, recvKey: kA2B, peerStaticPub: sPubA, sas: sas)
        } catch {
            await wire.close()
            throw error
        }
    }
}
