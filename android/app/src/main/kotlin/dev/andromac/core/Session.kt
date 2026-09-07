package dev.andromac.core

import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.Socket
import java.security.PrivateKey
import java.security.PublicKey

/**
 * The handshake verified cryptographically (the peer proved possession of its static private
 * key), but this device is not paired yet, or the pinned key has changed.
 */
class UntrustedPeerException(
    val peerStaticPub: ByteArray,
    val peerName: String,
    val sas: String,
    /** true means: a key was pinned before and it has CHANGED — a serious warning. */
    val pinMismatch: Boolean,
) : IOException(if (pinMismatch) "pinned key changed" else "device not paired")

/**
 * A docs/PROTOCOL.md §2/§4 session running over an already established TCP socket.
 * Android is always the initiator (role A).
 */
class Session internal constructor(
    private val socket: Socket,
    private val input: DataInputStream,
    private val output: DataOutputStream,
    private val sendKey: ByteArray,
    private val recvKey: ByteArray,
    val peerStaticPub: ByteArray,
    val sas: String,
) : AutoCloseable {

    private var sendCounter = 1L      // 0 was consumed by the confirmation round
    private var recvCounter = 1L

    @Synchronized
    fun send(msg: JSONObject) {
        val ct = Crypto.seal(sendKey, sendCounter++, msg.toString().toByteArray(Charsets.UTF_8))
        writeFrame(output, ct)
    }

    /** Reads and decrypts one message. The socket read timeout is the caller's responsibility. */
    fun receive(): JSONObject {
        val ct = readFrame(input)
        val pt = Crypto.open(recvKey, recvCounter++, ct)   // an AEAD failure means: drop the link
        return JSONObject(String(pt, Charsets.UTF_8))
    }

    override fun close() {
        // Deliberately NOT under the monitor: closing the socket is what unblocks a [send]
        // stuck writing to a peer that stopped reading. Taking the lock first would let a
        // stalled write hang whoever closes the link, including the main thread in onDestroy.
        runCatching { socket.close() }
        zeroKeys()
    }

    /**
     * Best-effort zeroing of the session keys so they do not linger in a heap dump or in swap
     * after close. Not a guarantee (the GC may have copied them), but it costs nothing.
     *
     * Synchronized against [send]: zeroing while a queued send sat inside `Crypto.seal` used
     * to produce a frame encrypted under a half-zeroed key. The socket is already closed by
     * the time we get here, so the in-flight write cannot block us for long.
     */
    @Synchronized
    private fun zeroKeys() {
        java.util.Arrays.fill(sendKey, 0)
        java.util.Arrays.fill(recvKey, 0)
    }

    companion object {
        const val MAX_FRAME = 1 shl 20      // 1 MiB, PROTOCOL §4
        private const val PROTO: Byte = 3   // handshake version byte, PROTOCOL §2
        private val LABEL = "AndroMac/v3".toByteArray(Charsets.UTF_8)

        private fun writeFrame(out: DataOutputStream, payload: ByteArray) {
            out.writeInt(payload.size)
            out.write(payload)
            out.flush()
        }

        private fun readFrame(input: DataInputStream): ByteArray {
            val n = input.readInt()
            if (n <= 0 || n > MAX_FRAME) throw IOException("invalid frame length: $n")
            return ByteArray(n).also(input::readFully)
        }

        /**
         * Client-side (role A) handshake.
         *
         * [pinnedKeyFor] returns the stored pin if there is one, otherwise null. A pinned key
         * that does not match ends the attempt before this phone's static key is sent
         * ([UntrustedPeerException] with `pinMismatch = true` and no SAS). With no pin, the
         * handshake completes, the peer proves its key, and the exception carries the SAS to
         * show; the socket is closed either way.
         */
        @Throws(IOException::class)
        fun connect(
            socket: Socket,
            staticPriv: PrivateKey,
            staticPubBytes: ByteArray,
            peerName: String,
            pinnedKeyFor: () -> ByteArray?,
        ): Session {
            val input = DataInputStream(socket.getInputStream().buffered())
            val output = DataOutputStream(socket.getOutputStream().buffered())

            // 1. A -> B — only the ephemeral key; the static key stays hidden until the Mac has
            //    proven (via dh3) to be the one we pinned, so a passive listener or a stranger
            //    that merely answers on the port never learns this phone's identity key.
            val eph = Crypto.generateKeyPair()
            val ePubA = Crypto.encodePublic(eph.public)
            output.write(byteArrayOf(PROTO))
            output.write(ePubA)
            output.flush()

            // 2. B -> A — e_B in the clear, then s_B and the nonce commitment c_B encrypted under
            //    the ephemeral-ephemeral secret. B commits to n_B before it sees n_A.
            val proto = input.read()
            if (proto == -1) throw EOFException("connection dropped during the handshake")
            if (proto != PROTO.toInt()) throw IOException("unsupported protocol version: $proto")
            val ePubB = ByteArray(Crypto.PUB_LEN).also(input::readFully)
            val ctB = ByteArray(Crypto.PUB_LEN + Crypto.NONCE_LEN + Crypto.TAG_LEN).also(input::readFully)

            val peerEph: PublicKey = Crypto.decodePublic(ePubB)   // on-curve validation happens here
            val h1 = Crypto.sha256(LABEL, ePubA, ePubB)
            val dh1 = Crypto.ecdh(eph.private, peerEph)           // forward secrecy
            val ptB = try {
                Crypto.open(Crypto.hkdf(h1, dh1, "AndroMac/v3 ee", 32), 0, ctB)
            } catch (e: Exception) {
                socket.close()
                throw IOException("message 2 failed to open — key agreement mismatch", e)
            }
            val sPubB = ptB.copyOfRange(0, Crypto.PUB_LEN)
            val cB = ptB.copyOfRange(Crypto.PUB_LEN, ptB.size)
            val peerStatic: PublicKey = Crypto.decodePublic(sPubB)

            // The pin is checked BEFORE our static key goes out: a changed key ends the attempt
            // here, with nothing about this phone revealed. There is no SAS yet — the user
            // resets the pairing and the next attempt shows a fresh code.
            val pinned = pinnedKeyFor()
            if (pinned != null && !Crypto.constantTimeEquals(pinned, sPubB)) {
                socket.close()
                throw UntrustedPeerException(sPubB, peerName, sas = "", pinMismatch = true)
            }

            // 3. A -> B — s_A encrypted so that only the holder of s_B's private key can read it.
            val dh3 = Crypto.ecdh(eph.private, peerStatic)        // identity of B
            val ctA = Crypto.seal(Crypto.hkdf(h1, dh1 + dh3, "AndroMac/v3 es", 32), 0, staticPubBytes)
            output.write(ctA)

            val transcript = Crypto.sha256(LABEL, ePubA, ePubB, ctB, ctA)
            val ikm = dh1 +
                Crypto.ecdh(staticPriv, peerEph) +             // dh2: identity of A
                dh3
            val sendKey = Crypto.hkdf(transcript, ikm, "AndroMac a2b", 32)
            val recvKey = Crypto.hkdf(transcript, ikm, "AndroMac b2a", 32)

            // 3./4. Confirmation round — nonce 0, plaintext = transcript || own nonce. Sent in
            //    the same flush as ct_A.
            val nA = Crypto.randomBytes(Crypto.NONCE_LEN)
            writeFrame(output, Crypto.seal(sendKey, 0, transcript + nA))
            val theirs = try {
                Crypto.open(recvKey, 0, readFrame(input))
            } catch (e: Exception) {
                socket.close()
                throw IOException("confirmation round failed — key agreement mismatch or MITM", e)
            }
            if (theirs.size != transcript.size + Crypto.NONCE_LEN ||
                !Crypto.constantTimeEquals(theirs.copyOfRange(0, transcript.size), transcript)
            ) {
                socket.close()
                throw IOException("transcript mismatch — suspected MITM")
            }
            val nB = theirs.copyOfRange(transcript.size, theirs.size)
            if (!Crypto.constantTimeEquals(Crypto.commit(nB), cB)) {
                socket.close()
                throw IOException("nonce commitment mismatch — suspected MITM")
            }

            // Past this point the peer has proven possession of the s_B private key.
            val sas = Crypto.sas(transcript, nA, nB)
            if (pinned == null) {
                socket.close()
                throw UntrustedPeerException(sPubB, peerName, sas, pinMismatch = false)
            }

            return Session(socket, input, output, sendKey, recvKey, sPubB, sas)
        }
    }
}
