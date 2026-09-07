package dev.andromac.vectors

import dev.andromac.core.Crypto
import dev.andromac.core.Protocol
import dev.andromac.core.Session
import dev.andromac.core.UntrustedPeerException
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.Socket

/**
 * The client (role A) that runs the real `Session.connect` code on a plain JVM.
 * It connects to the `andromac-selftest handshake <port>` responder.
 *
 * Three rounds:
 *  1. No pin -> we expect an UntrustedPeerException; the SAS must be THE SAME on both sides.
 *  2. A different key pinned -> the phone must stop before sending its static key (no SAS).
 *  3. The learned key pinned -> the session must come up, hello must arrive, and a message
 *     must go out.
 */
fun runHandshakeClient(host: String, port: Int) {
    val priv = privateFromScalar(ByteArray(32) { 0x11 })
    val pub = unhex(PUB1_HEX)

    // Round 1 — unpaired
    var learned: ByteArray? = null
    connect(host, port) { socket ->
        try {
            Session.connect(socket, priv, pub, "SelfTestMac", pinnedKeyFor = { null })
            println("round1=UNEXPECTED_SUCCESS")
        } catch (e: UntrustedPeerException) {
            println("round1=untrusted sas=${e.sas} mismatch=${e.pinMismatch}")
            println("round1_peerkey=${hex(e.peerStaticPub)}")
            learned = e.peerStaticPub
        }
    }

    val pinned = learned
    if (pinned == null) {
        println("round2=skipped (round 1 did not learn a key)")
        return
    }

    // Round 2 — a DIFFERENT key pinned: the attempt must stop before our static key goes out
    // (no SAS), and the responder must see message 3 never arrive.
    val wrong = pinned.copyOf().also { it[it.lastIndex] = (it[it.lastIndex].toInt() xor 1).toByte() }
    connect(host, port) { socket ->
        try {
            Session.connect(socket, priv, pub, "SelfTestMac", pinnedKeyFor = { wrong })
            println("round2=UNEXPECTED_SUCCESS")
        } catch (e: UntrustedPeerException) {
            println("round2=untrusted sas=${e.sas} mismatch=${e.pinMismatch}")
        }
    }

    // Round 3 — pinned
    connect(host, port) { socket ->
        Session.connect(socket, priv, pub, "SelfTestMac", pinnedKeyFor = { pinned }).use { session ->
            println("round3=connected sas=${session.sas}")
            val hello = session.receive()
            println("round3_hello=${hello.optString("t")} name=${hello.optString("name")}")

            // Counter progression: MESSAGE_COUNT frames in each direction. A single message
            // never pushes the nonce past 1; a counter bug shows up on the Nth message, not
            // on the first.
            val received = ArrayList<Int>(MESSAGE_COUNT)
            for (i in 1..MESSAGE_COUNT) {
                received += session.receive().optInt("seq", -1)
            }
            println("round3_seq=${received.joinToString(",")}")
            for (i in 1..MESSAGE_COUNT) {
                session.send(JSONObject().put("t", "pong").put("seq", i))
            }

            session.send(Protocol.clipboard("merhaba mac"))
            println("round3_sent=clipboard")
            Thread.sleep(300)      // give the responder time to read
        }
    }
}

/** Must be THE SAME as `messageCount` on the Swift side. */
private const val MESSAGE_COUNT = 12

private fun connect(host: String, port: Int, body: (Socket) -> Unit) {
    Socket().use { socket ->
        socket.tcpNoDelay = true
        socket.connect(InetSocketAddress(host, port), 5_000)
        socket.soTimeout = 10_000
        body(socket)
    }
}
