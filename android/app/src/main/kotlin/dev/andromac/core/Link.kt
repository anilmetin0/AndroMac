package dev.andromac.core

import android.util.Log
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * The single in-process link state. The NotificationListenerService, the QS tile and the
 * activities are not separate process components; they all talk through here, so no IPC.
 */
object Link {

    sealed interface State {
        data object Stopped : State
        data object Searching : State
        data class Connected(val peerName: String) : State
        data class NeedsPairing(val peerKey: ByteArray, val peerName: String, val sas: String) : State
        data class KeyChanged(val peerName: String, val sas: String) : State
    }

    @Volatile private var session: Session? = null

    @Volatile
    var state: State = State.Stopped
        private set

    /**
     * Live diagnostic for the setup guide: was the Mac seen during the last scan?
     *
     * Telling the user "cannot connect" does not help; telling them which step is stuck does.
     * If the mDNS scan finds the Mac, the problem is pairing rather than the network; if it
     * does not, either the network is wrong or the Mac app is not running.
     */
    @Volatile
    var macSeenOnNetwork: Boolean = false
        internal set

    /**
     * The Macs the last mDNS browse saw, in the order found: Bonjour instance name to the Mac's
     * own TXT `n` (the instance name until it resolves). The screen says which Mac a pairing goes
     * to when there is more than one. Written by [dev.andromac.net.Discovery]
     * only while it browses; no extra scan exists for it.
     */
    @Volatile
    var discoveredMacs: Map<String, String> = emptyMap()
        private set

    /** NSD callbacks can arrive on several threads; the read-modify-write is serialized here. */
    internal fun setDiscovered(update: (Map<String, String>) -> Map<String, String>) {
        val changed = synchronized(this) {
            val next = update(discoveredMacs)
            (next != discoveredMacs).also { discoveredMacs = next }
        }
        if (changed) listeners.forEach { runCatching { it(state) } }
    }

    private val listeners = CopyOnWriteArrayList<(State) -> Unit>()

    fun addListener(l: (State) -> Unit) { listeners += l; l(state) }
    fun removeListener(l: (State) -> Unit) { listeners -= l }

    /**
     * The same state twice is one event. The connection loop re-enters Searching on every
     * attempt, and each redundant event re-rendered the main screen, which read as a flicker.
     */
    internal fun setState(s: State) {
        if (s == state) return
        state = s
        listeners.forEach { runCatching { it(s) } }
    }

    /**
     * Publishes [s] with [hello] already first in the send queue: nothing another thread sends can
     * go out ahead of it, and a Mac that has this phone's auto-connect off reads the hello first to
     * decide whether to let it in (PROTOCOL §3).
     */
    internal fun attach(s: Session, hello: JSONObject) {
        io.execute { write(s, hello) }
        session = s
    }
    internal fun detach() { session = null }

    val isConnected: Boolean get() = session != null

    /**
     * Most callers run on the main thread (NotificationListenerService, BroadcastReceiver,
     * activities). A socket write there throws `NetworkOnMainThreadException`, so sending is
     * handed to one background thread — being single-threaded also preserves ordering.
     */
    private val io = Executors.newSingleThreadExecutor { r ->
        Thread(r, "andromac-send").apply { isDaemon = true }
    }

    /** Holds the fallback close of [hangUp]. */
    private val timer by lazy {
        Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "andromac-hangup").apply { isDaemon = true } }
    }

    /**
     * Send [last] and then hang up, in that order; false with no link. A write stuck on a Mac that
     * stopped reading would hold the close back for the whole read timeout, and the close is what
     * frees such a write ([Session.close]), so it also comes on its own after [HANG_UP_GRACE_MS].
     */
    fun hangUp(last: JSONObject): Boolean {
        val s = session ?: return false
        io.execute {
            runCatching { s.send(last) }
            s.close()
        }
        timer.schedule({ s.close() }, HANG_UP_GRACE_MS, TimeUnit.MILLISECONDS)
        return true
    }

    /** True if the message was queued. With no link it is dropped silently (PROTOCOL §6 — nothing is buffered). */
    fun send(msg: JSONObject): Boolean {
        val s = session ?: return false
        io.execute {
            if (session !== s) return@execute        // drop it if the link changed in the meantime
            write(s, msg)
        }
        return true
    }

    private fun write(s: Session, msg: JSONObject) {
        try {
            s.send(msg)
        } catch (e: Exception) {
            Log.w(TAG, "send failed, dropping the link", e)
            s.close()
        }
    }

    private const val HANG_UP_GRACE_MS = 1_000L
    const val TAG = "AndroMac"
}
