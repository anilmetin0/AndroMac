package dev.andromac.net

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.SystemClock
import android.util.Log
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Protocol
import dev.andromac.core.Session
import dev.andromac.core.Store
import dev.andromac.core.UntrustedPeerException
import dev.andromac.feature.BatteryReporter
import dev.andromac.feature.ClipboardBridge
import dev.andromac.feature.FileTransfer
import dev.andromac.feature.FindPhone
import dev.andromac.feature.IconProvider
import dev.andromac.feature.MediaBridge
import dev.andromac.feature.NotificationRelay
import dev.andromac.feature.SystemBridge
import dev.andromac.ui.ClipHelperActivity
import dev.andromac.ui.MainActivity
import org.json.JSONObject
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * The foreground service that owns the single long-lived link.
 *
 * Energy contract (PROTOCOL §6):
 *  - No periodic timers at all. Waiting goes through [lock].wait(); wake-ups come either
 *    from a network event or from the user.
 *  - While connected, the mDNS scan is off.
 *  - The read loop blocks; liveness comes from the Mac's ping plus SO_TIMEOUT.
 */
class LinkService : Service() {

    private lateinit var store: Store
    private lateinit var battery: BatteryReporter
    private lateinit var clipboard: ClipboardBridge
    private lateinit var icons: IconProvider
    private lateinit var media: MediaBridge
    private lateinit var system: SystemBridge

    /**
     * Wake-up signal for the link thread. A permit released by [wake] before the thread
     * reaches [await] is consumed there, so a wake-up racing the thread into the wait can no
     * longer be lost — the plain monitor this replaced dropped it and parked forever.
     */
    private val wakeups = Semaphore(0)
    @Volatile private var running = false
    @Volatile private var worker: Thread? = null
    /** The user started the pairing flow: turn this round's pin check into a SAS prompt. */
    @Volatile private var pairingRequested = false

    private var netCallback: ConnectivityManager.NetworkCallback? = null
    /** The open session. If onDestroy does not close the socket, the read loop lives on for another 300 s. */
    @Volatile private var current: Session? = null

    override fun onBind(intent: Intent?) = null

    override fun onCreate() {
        super.onCreate()
        store = Store(this)
        battery = BatteryReporter(this, store)
        clipboard = ClipboardBridge(this, store)
        icons = IconProvider(this)
        media = MediaBridge(this, store)
        system = SystemBridge(this)
        createChannels()
        startForeground(FGS_ID, buildNotification(getString(R.string.fgs_starting), false))
        // A process death during the 30 s alarm leaves the alarm stream pinned at maximum.
        FindPhone.restoreAlarmVolume(this)
        registerNetworkCallback()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PAIR) {
            pairingRequested = true
            // A user request counts as an event: restart the ladder and browse on the next
            // attempt instead of waiting for the every-Nth-attempt slot.
            backoffIndex = 0
            attempt = 0
            wake()
        }
        // Never start a second worker: a START_STICKY restart can arrive while the old
        // thread is still winding down, which used to produce two parallel connections.
        if (!running && worker?.isAlive != true) {
            running = true
            worker = Thread(::loop, "andromac-link").apply { isDaemon = true; start() }
        }
        wake()
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        // The read blocks on the socket: running=false alone would not wake it for 300 s.
        current?.close()
        worker?.interrupt()
        wake()
        battery.stop()
        netCallback?.let { runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) } }
        Link.detach()
        Link.setState(Link.State.Stopped)
        super.onDestroy()
    }

    // ---------------------------------------------------------------- connection loop

    private val backoff = longArrayOf(1_000, 2_000, 5_000, 15_000, 60_000, 300_000)
    @Volatile private var backoffIndex = 0
    /** Monotonic time of the last ladder reset; the flap guard in `onAvailable` reads it. */
    @Volatile private var lastLadderReset = 0L
    /** Failed dial attempts since the last network event, pairing request or live link. */
    @Volatile private var attempt = 0
    /** True when the socket in hand came from [Store.lastEndpoint] rather than from mDNS. */
    private var dialedFromCache = false

    private fun loop() {
        val (priv, pub) = store.identity()
        val discovery = Discovery(this)

        while (running) {
            if (!store.isPaired && !pairingRequested) {
                Link.setState(Link.State.Stopped)
                note(getString(R.string.fgs_no_pair))
                await(0)                     // indefinite: wakes when the user starts pairing
                continue
            }

            Link.setState(Link.State.Searching)
            note(getString(R.string.state_searching))

            val dialed = dial(discovery)
            if (dialed == null) {
                sleepBackoff()
                continue
            }
            val (socket, peerName) = dialed

            try {
                socket.use { s ->
                    // A host that accepts the connection and then stays silent must not pin
                    // the only link thread for the whole read timeout. macOS enforces the same
                    // 10 s on its side (PROTOCOL §3); the long timeout starts once we are up.
                    s.soTimeout = HANDSHAKE_TIMEOUT_MS
                    // The pin is ALWAYS checked. Tapping "Pair" does NOT discard it: a changed
                    // key must surface as a KeyChanged warning rather than as a first contact
                    // (PROTOCOL §3). pairingRequested only allows the attempt when nothing is
                    // paired yet; for a deliberate re-pair, "Reset pairing" already calls unpair().
                    val session = Session.connect(
                        s, priv, pub, peerName, pinnedKeyFor = { store.pairedKey },
                    )
                    s.soTimeout = READ_TIMEOUT_MS
                    // The handshake gave a definitive answer, so the flag has done its job.
                    // Leaving it set kept the loop dialling forever after a later unpair.
                    pairingRequested = false
                    Link.macSeenOnNetwork = true
                    store.lastEndpoint = "${s.inetAddress.hostAddress}:${s.port}"
                    backoffIndex = 0
                    attempt = 0
                    serve(session, peerName)
                }
            } catch (e: UntrustedPeerException) {
                pairingRequested = false
                Link.setState(
                    if (e.pinMismatch) Link.State.KeyChanged(e.peerName, e.sas)
                    else Link.State.NeedsPairing(e.peerStaticPub, e.peerName, e.sas)
                )
                note(
                    if (e.pinMismatch) getString(R.string.fgs_key_changed)
                    else getString(R.string.fgs_waiting, e.sas)
                )
                await(0)                     // hold until the user confirms
                continue
            } catch (e: IOException) {
                Log.i(Link.TAG, "connection failed: ${e.message}")
                forgetCachedEndpoint()
                sleepBackoff()
                continue
            } catch (e: Exception) {
                Log.w(Link.TAG, "unexpected connection error", e)
                forgetCachedEndpoint()
                sleepBackoff()
                continue
            }
        }
    }

    /**
     * A connected socket plus the peer name. The last known address is tried first and the
     * SUCCESSFUL SOCKET IS REUSED: the old version opened a probe socket, closed it, and then
     * dialled again — ENERGY §6 promises exactly one handshake per reconnect. If that address
     * does not work, it falls back to mDNS (PROTOCOL §1).
     */
    private fun dial(discovery: Discovery): Pair<Socket, String>? {
        dialedFromCache = false
        val cached = store.lastEndpoint
        cached?.let { ep ->
            runCatching {
                val i = ep.lastIndexOf(':')
                val port = ep.substring(i + 1).toInt()
                java.net.InetAddress.getByName(ep.substring(0, i)) to port
            }.getOrNull()?.let { (host, port) ->
                connect(host, port)?.let {
                    dialedFromCache = true
                    return it to store.pairedName
                }
            }
        }
        // ENERGY §13. The cached-address SYN above is cheap and runs every cycle; the 8 s
        // multicast-locked browse is not, so it runs only on the first attempt after a network
        // event or a pairing request, then on every BROWSE_EVERY-th attempt. With no cached
        // address it runs every cycle: there is nothing cheaper left that could make progress.
        val browse = cached == null || attempt % BROWSE_EVERY == 0
        attempt++
        if (!browse) return null
        val peer = discovery.findOne()
        Link.macSeenOnNetwork = peer != null
        peer ?: return null
        return connect(peer.host, peer.port)?.let { it to peer.name }
    }

    /**
     * The cached address answered TCP but no session came out of it: it is not the Mac any
     * more (DHCP moved it, another service took the port). Drop it, otherwise every cycle
     * fails in the handshake and the mDNS browse is never reached again.
     */
    private fun forgetCachedEndpoint() {
        if (dialedFromCache) store.lastEndpoint = null
    }

    private fun connect(host: java.net.InetAddress, port: Int): Socket? {
        val socket = Socket()
        return try {
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            socket
        } catch (e: IOException) {
            Log.i(Link.TAG, "could not connect to $host:$port (${e.message})")
            runCatching { socket.close() }
            null
        }
    }

    /** The session is up: process messages. Blocks and does not return until the link drops. */
    private fun serve(session: Session, peerName: String) {
        current = session
        Link.attach(session)
        Link.setState(Link.State.Connected(peerName))
        note(getString(R.string.fgs_connected, peerName), connected = true)
        session.send(Protocol.hello(store.deviceName))
        battery.start()
        media.start()
        system.start()
        NotificationRelay.pushExisting()

        try {
            while (running) {
                val msg = try {
                    session.receive()
                } catch (e: java.net.SocketTimeoutException) {
                    // The Mac pings every 240 s and READ_TIMEOUT sits above that. Silence means a dead link.
                    Log.i(Link.TAG, "silence timeout, will reconnect")
                    break
                }
                handle(msg, session)
            }
        } catch (e: Exception) {
            Log.i(Link.TAG, "session ended: ${e.message}")
        } finally {
            current = null
            battery.stop()
            media.stop()
            system.stop()
            // If the link dropped, no second message will ever arrive to silence the alarm.
            FindPhone.stop(this)
            // Nothing is resumed: temporary files go, the send queue is emptied (PROTOCOL §5).
            FileTransfer.onSessionEnded(this)
            Link.detach()
            session.close()
        }
    }

    private fun handle(msg: JSONObject, session: Session) {
        val t = msg.optString("t")
        if (t.startsWith("file_")) { FileTransfer.handle(this, msg); return }
        when (t) {
            Protocol.T_PING -> session.send(Protocol.pong())
            Protocol.T_CLIPBOARD -> clipboard.receiveFromMac(msg.optString("text"))
            Protocol.T_NOTIFICATION_ACTION -> NotificationRelay.runAction(
                msg.optString("id"), msg.optInt("action", -1), msg.optString("reply").ifEmpty { null },
            )
            Protocol.T_NOTIFICATION_DISMISS -> NotificationRelay.dismiss(msg.optString("id"))
            Protocol.T_ICON_REQUEST -> icons.sendIcon(msg.optString("pkg"))
            Protocol.T_APP_MODE -> NotificationRelay.applyMode(
                msg.optString("pkg"), msg.optInt("mode", -1),
            )
            Protocol.T_FIND_PHONE -> FindPhone.start(this)
            Protocol.T_MEDIA_CONTROL -> media.control(msg.optString("cmd"))
            Protocol.T_SYSTEM_CONTROL -> system.control(msg)
            Protocol.T_CLIPBOARD_REQUEST -> clipboard.macAskedForClipboard()
            Protocol.T_HELLO -> {
                store.pairedName = msg.optString("name", store.pairedName).take(64)
                Link.setState(Link.State.Connected(store.pairedName))
                note(getString(R.string.fgs_connected, store.pairedName), connected = true)
            }
            else -> Unit                     // unknown type: ignore silently (forward compatibility)
        }
    }

    // ---------------------------------------------------------------- sleep / wake

    private fun sleepBackoff() {
        val ms = backoff[backoffIndex.coerceAtMost(backoff.lastIndex)]
        if (backoffIndex < backoff.lastIndex) backoffIndex++
        note(getString(R.string.fgs_retry, ms / 1000))
        await(ms)
    }

    /** Waits up to [ms] (0 = until woken). Returns immediately if a [wake] already arrived. */
    private fun await(ms: Long) {
        runCatching {
            if (ms <= 0) wakeups.acquire() else wakeups.tryAcquire(ms, TimeUnit.MILLISECONDS)
        }
        wakeups.drainPermits()          // a burst of wake-ups is still just one wake-up
    }

    private fun wake() {
        wakeups.release()
    }

    /** Retry the moment the network comes back — an event instead of polling. PROTOCOL §6.4 */
    private fun registerNetworkCallback() {
        val cm = getSystemService(ConnectivityManager::class.java)
        // NET_CAPABILITY_INTERNET is deliberately NOT requested: on LAN-only and captive
        // portal networks that capability never arrives, the callback never fires, and
        // recovery would fall back to the 300 s ceiling. Cellular is left out as well: waking
        // up on mobile data would only buy a wasted mDNS scan.
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // Flap guard: a weak Wi-Fi link fires this several times in a row, and each
                // event used to restart the ladder at 1 s and dial again immediately. Once we
                // are at the bottom of the ladder, further events inside FLAP_GUARD_MS are
                // ignored; a genuine return of the network is still handled by the first one.
                val now = SystemClock.elapsedRealtime()
                if (backoffIndex == 0 && now - lastLadderReset < FLAP_GUARD_MS) return
                lastLadderReset = now
                backoffIndex = 0
                attempt = 0
                wake()
            }
        }
        netCallback = cb
        runCatching { cm.registerNetworkCallback(req, cb) }
    }

    // ---------------------------------------------------------------- notification

    private fun createChannels() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_STATUS, getString(R.string.channel_status),
                NotificationManager.IMPORTANCE_MIN,
            )
                .apply { setShowBadge(false) }
        )
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_CLIP, getString(R.string.clip_incoming_title),
                NotificationManager.IMPORTANCE_LOW,
            )
        )
    }

    /**
     * While connected, a "Send clipboard to Mac" action is added to the ongoing notification:
     * Android 10+ only exposes the clipboard to the focused app, so sending has to be
     * user-triggered; this is the second, always-visible route next to the QS tile.
     */
    private fun buildNotification(text: String, connected: Boolean): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = Notification.Builder(this, CHANNEL_STATUS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
        if (connected) {
            val send = PendingIntent.getActivity(
                this, REQ_CLIP, ClipHelperActivity.getIntent(this),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            builder.addAction(
                Notification.Action.Builder(
                    null as android.graphics.drawable.Icon?, getString(R.string.tile_clip), send,
                ).build()
            )
        }
        return builder.build()
    }

    private fun note(text: String, connected: Boolean = false) {
        getSystemService(NotificationManager::class.java)
            .notify(FGS_ID, buildNotification(text, connected))
    }

    companion object {
        const val ACTION_PAIR = "dev.andromac.PAIR"
        const val CHANNEL_STATUS = "status"
        const val CHANNEL_CLIP = "clipboard"
        private const val FGS_ID = 1
        private const val REQ_CLIP = 5
        private const val CONNECT_TIMEOUT_MS = 5_000
        /** The Mac pings every 240 s (PROTOCOL §6.1); 300 s leaves slack. */
        private const val READ_TIMEOUT_MS = 300_000
        /** The handshake budget both sides enforce (PROTOCOL §3). */
        private const val HANDSHAKE_TIMEOUT_MS = 10_000
        /** One mDNS browse per this many failed attempts while an address is cached. */
        private const val BROWSE_EVERY = 4
        /** Repeated `onAvailable` events inside this window do not restart the ladder. */
        private const val FLAP_GUARD_MS = 10_000L

        fun start(ctx: Context, action: String? = null) {
            val i = Intent(ctx, LinkService::class.java).apply { if (action != null) this.action = action }
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }
    }
}
