package dev.andromac.core

import android.util.Log
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

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

    private val listeners = CopyOnWriteArrayList<(State) -> Unit>()

    fun addListener(l: (State) -> Unit) { listeners += l; l(state) }
    fun removeListener(l: (State) -> Unit) { listeners -= l }

    internal fun setState(s: State) {
        state = s
        listeners.forEach { runCatching { it(s) } }
    }

    internal fun attach(s: Session) { session = s }
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

    /** True if the message was queued. With no link it is dropped silently (PROTOCOL §6 — nothing is buffered). */
    fun send(msg: JSONObject): Boolean {
        val s = session ?: return false
        io.execute {
            if (session !== s) return@execute        // drop it if the link changed in the meantime
            try {
                s.send(msg)
            } catch (e: Exception) {
                Log.w(TAG, "send failed, dropping the link", e)
                s.close()
            }
        }
        return true
    }

    const val TAG = "AndroMac"
}
