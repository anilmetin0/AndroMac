package io.github.anilmetin0.andromac.core

import java.net.InetAddress

/**
 * Which discovered Mac to dial, and what a pin mismatch means. Pure Kotlin, unit-tested in
 * :vectors. The Bonjour record carries no key (PROTOCOL §1), so the advertised name is the only
 * hint before the handshake proves who answered.
 */
object MacPick {

    /** [service] is the Bonjour instance name (unique on the LAN), [name] the Mac's own `n`. */
    data class Peer(val host: InetAddress, val port: Int, val service: String, val name: String) {
        /** How a Mac that is not ours is remembered for the rest of this network session. */
        val id: String get() = "$service@${host.hostAddress}"
    }

    /**
     * Pairing with [target]: that service only. Paired: Macs already proven not ours are
     * dropped, and the one advertising the saved name goes first.
     */
    fun dialOrder(peers: List<Peer>, pairedName: String, notOurs: Set<String>, target: String?): List<Peer> =
        if (target != null) peers.filter { it.service == target }
        else peers.filter { it.id !in notOurs }.sortedBy { it.name != pairedName }

    /**
     * A pinned key that does not match is a key change only when the Mac claims our Mac's name
     * (or no name was saved). Any other Mac is simply somebody else's, and is skipped quietly.
     */
    fun isKeyChange(advertisedName: String, pairedName: String): Boolean =
        pairedName.isEmpty() || advertisedName == pairedName

    /**
     * After a pin mismatch with [dialed]: true to mark it not ours and dial the next. A Mac with
     * our Mac's name is a key change only once no other Mac of that name is [left] to try: a
     * neighbour may have named theirs the same.
     */
    fun skipOnMismatch(dialed: Peer, pairedName: String, left: Collection<Peer>): Boolean =
        !isKeyChange(dialed.name, pairedName) || left.any { it.name == pairedName }
}
