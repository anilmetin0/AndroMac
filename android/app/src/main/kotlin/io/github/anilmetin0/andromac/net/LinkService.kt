package io.github.anilmetin0.andromac.net

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import io.github.anilmetin0.andromac.R
import io.github.anilmetin0.andromac.core.Link
import io.github.anilmetin0.andromac.core.MacPick
import io.github.anilmetin0.andromac.core.NetworkInfo
import io.github.anilmetin0.andromac.core.Protocol
import io.github.anilmetin0.andromac.core.Session
import io.github.anilmetin0.andromac.core.Store
import io.github.anilmetin0.andromac.core.UntrustedPeerException
import io.github.anilmetin0.andromac.feature.BatteryReporter
import io.github.anilmetin0.andromac.feature.ClipboardBridge
import io.github.anilmetin0.andromac.feature.FileTransfer
import io.github.anilmetin0.andromac.feature.FindPhone
import io.github.anilmetin0.andromac.feature.IconProvider
import io.github.anilmetin0.andromac.feature.MediaBridge
import io.github.anilmetin0.andromac.feature.NotificationRelay
import io.github.anilmetin0.andromac.feature.SystemBridge
import io.github.anilmetin0.andromac.ui.ClipHelperActivity
import io.github.anilmetin0.andromac.ui.MainActivity
import org.json.JSONObject
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
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
    /** The Bonjour instance the user picked out of several Macs; null pairs with the only one. */
    @Volatile private var pairTarget: String? = null

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
        when (intent?.action) {
            ACTION_PAIR -> {
                pairTarget = intent.getStringExtra(EXTRA_MAC)
                pairingRequested = true
                notOurs.clear()              // "not ours" was measured against the old pin
                restartLadder()
            }
            ACTION_CONNECT -> { connectRequested = true; restartLadder() }
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
        system.close()
        netCallback?.let { runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) } }
        screenReceiver?.let { runCatching { unregisterReceiver(it) } }
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
    /** Browsed Macs not dialled yet this round, best first ([MacPick.dialOrder]). Link thread only. */
    private val pending = ArrayDeque<MacPick.Peer>()
    /** The browsed Mac the socket in hand leads to; null for the cached address. */
    private var dialedPeer: MacPick.Peer? = null
    /**
     * Macs on this network that proved they are somebody else's ([MacPick.Peer.id]). They are
     * not dialled again until the network changes or a new pairing starts. Memory only.
     */
    private val notOurs: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private var notOursNet: String? = null
    /** "Connect now" with auto-connect off: one full attempt, then park again. */
    @Volatile private var connectRequested = false
    private var screenReceiver: BroadcastReceiver? = null

    /**
     * The Wi-Fi and Ethernet networks that are up right now. With none, nothing is dialled: the
     * Mac is only ever on a LAN, and a SYN to its private address over mobile data would wake the
     * cellular radio (seconds of high-power tail) for a connection that cannot succeed. Sockets are
     * also bound to one of these, so a Wi-Fi without internet access, where Android keeps mobile
     * data as the default route, still reaches the Mac.
     */
    private val lanNetworks: MutableSet<Network> = ConcurrentHashMap.newKeySet()

    /** False if the network callback could not be registered: then nothing is gated on it. */
    @Volatile private var watchingNetworks = false

    /**
     * The Mac said it is going to sleep. Until the network changes, the screen comes on or a
     * session comes up, the ladder stays at its ceiling and mDNS is not run: a sleeping Mac
     * answers neither, and a night of 5-attempt bursts is exactly the waste this avoids.
     */
    @Volatile private var macAsleep = false

    /** The LAN to bind to: the default network when it is one, otherwise any. */
    private fun lanNetwork(): Network? {
        val active = getSystemService(ConnectivityManager::class.java).activeNetwork
        return active?.takeIf { it in lanNetworks } ?: lanNetworks.firstOrNull()
    }

    /** The last text on the ongoing notification: an unchanged one is not re-posted every cycle. */
    private var lastNote: Pair<String, Boolean>? = null

    /** A user request or a network event counts as a fresh start: ladder at 1 s, browse next. */
    private fun restartLadder() {
        macAsleep = false
        backoffIndex = 0
        attempt = 0
        wake()
    }

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
            if (store.isPaired && !store.autoConnect && !connectRequested) {
                Link.setState(Link.State.Stopped)
                note(getString(R.string.state_auto_off))
                await(0)                     // indefinite: wakes on "Connect now" or the switch
                continue
            }
            if (watchingNetworks && lanNetworks.isEmpty()) {
                Link.setState(Link.State.Searching)
                note(getString(R.string.onboarding_step2_none))
                await(0)                     // indefinite: the network callback wakes it
                continue
            }
            connectRequested = false         // one attempt per request

            Link.setState(Link.State.Searching)
            note(getString(if (store.isPaired) R.string.state_waiting_mac else R.string.state_searching))

            val dialed = dial(discovery)
            if (dialed == null) {
                // Several Macs and none picked: park until the user chooses one.
                if (!store.isPaired && !pairingRequested) continue
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
                    pairTarget = null
                    pending.clear()
                    Link.macSeenOnNetwork = true
                    store.lastEndpoint = "${s.inetAddress.hostAddress}:${s.port}"
                    store.macNetwork = networkKey()
                    serve(session, peerName)
                }
                // The ladder is reset by the Mac's hello, not by the handshake: a Mac that
                // completes the handshake and then hangs up (this phone is disconnected there,
                // or not approved yet) must not be redialled in a tight loop (PROTOCOL §3).
                if (macAsleep) backoffIndex = backoff.lastIndex
                sleepBackoff()
            } catch (e: UntrustedPeerException) {
                val peer = dialedPeer
                if (e.pinMismatch && dialedFromCache) {
                    // The key is unproven on a bare address: the browse decides by the name the
                    // Mac advertises there, right away (no cached address means it runs).
                    store.lastEndpoint = null
                    continue
                }
                if (e.pinMismatch && peer != null && MacPick.skipOnMismatch(peer, store.pairedName, pending)) {
                    // Somebody else's Mac on this Wi-Fi (another name, or ours is still to be
                    // tried under the same name), not a key change: skip it quietly and for good
                    // on this network. The next candidate goes now, otherwise the ladder.
                    notOurs += peer.id
                    if (pending.isEmpty()) sleepBackoff()
                    continue
                }
                pairingRequested = false
                pairTarget = null
                pending.clear()
                if (!e.pinMismatch) notOurs.clear()   // a new pin is about to be saved
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
     * does not work, it falls back to mDNS (PROTOCOL §1). Macs left over from the last browse
     * are dialled before anything else, without a new browse.
     */
    private fun dial(discovery: Discovery): Pair<Socket, String>? {
        dialedFromCache = false
        dialedPeer = null
        // "Not ours" holds for one network: somebody else's Mac on this Wi-Fi.
        networkKey().let { if (it != notOursNet) { notOurs.clear(); pending.clear(); notOursNet = it } }
        if (attempt == 0) pending.clear()    // a network event or a request: browse afresh
        if (pending.isNotEmpty()) return dialPending()
        val cached = store.lastEndpoint
        // The cached address belongs to the Mac's own LAN; on another network it is somebody
        // else's host, or nobody's.
        cached?.takeIf { onMacNetwork() }?.let { ep ->
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
        // On a network where the Mac has never answered (the office, a café) the browse runs once
        // per network event, not every 4th attempt: the Mac is very likely not there at all.
        val browse = !macAsleep &&
            (cached == null || attempt == 0 || (onMacNetwork() && attempt % BROWSE_EVERY == 0))
        attempt++
        if (!browse) return null
        val paired = store.isPaired
        val name = store.pairedName
        val target = pairTarget.takeUnless { paired }
        // Paired: a moment more after the first Mac with our Mac's name, so a neighbour's Mac of the
        // same name does not hide ours. Pairing with no pick: a longer moment after the first, so
        // a second Mac is not missed and paired with by accident.
        val settle = when {
            target != null -> 0L
            paired -> PAIRED_SETTLE_MS
            else -> PAIR_SETTLE_MS
        }
        val peers = discovery.browse(settleMs = settle) { found ->
            when {
                target != null -> found.any { it.service == target }
                paired -> found.any { it.id !in notOurs && (name.isEmpty() || it.name == name) }
                else -> found.isNotEmpty()
            }
        }
        Link.macSeenOnNetwork = peers.isNotEmpty()
        if (target != null && peers.none { it.service == target }) {
            // The Mac picked in the chooser did not answer: stop, and let Pair offer the list again.
            pairingRequested = false
            pairTarget = null
            Link.setState(Link.State.Stopped)
            return null
        }
        if (!paired && target == null && Link.discoveredMacs.size > 1) {
            // Several Macs: the user picks one (MainActivity's chooser); none is dialled on a guess.
            pairingRequested = false
            Link.setState(Link.State.Stopped)
            return null
        }
        pending.addAll(MacPick.dialOrder(peers, name, notOurs, target))
        return dialPending()
    }

    private fun dialPending(): Pair<Socket, String>? {
        while (true) {
            val peer = pending.removeFirstOrNull() ?: return null
            connect(peer.host, peer.port)?.let {
                dialedPeer = peer
                return it to peer.name
            }
        }
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
            lanNetwork()?.bindSocket(socket)
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
        // Through the send queue, like everything else: a direct write from this read thread would
        // wait on the session lock while the queue is mid-chunk, and a Mac blocked writing to us
        // at the same moment would never be read (both sides stuck on a full socket buffer).
        Link.send(Protocol.hello(store.deviceName))
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
            Protocol.T_SLEEP -> {
                macAsleep = true
                session.close()              // the read below ends, and the loop parks at the ceiling
            }
            Protocol.T_PING -> {
                // The ping already woke the Wi-Fi radio: a held-back battery report rides along.
                battery.flush()
                Link.send(Protocol.pong())
            }
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
                // The Mac let us in: this is a working link, so the next drop starts the ladder over.
                macAsleep = false
                backoffIndex = 0
                attempt = 0
                store.pairedName = Store.clip(msg.optString("name", store.pairedName), 64)
                Link.setState(Link.State.Connected(store.pairedName))
                note(getString(R.string.fgs_connected, store.pairedName), connected = true)
            }
            else -> Unit                     // unknown type: ignore silently (forward compatibility)
        }
    }

    // ---------------------------------------------------------------- sleep / wake

    /**
     * Wait before the next attempt. The ladder tops out at 300 s, which is right for a phone in a
     * pocket, and wrong for one in the hand: with the screen on, the Wi-Fi radio is awake anyway
     * and a SYN to the cached address costs nothing, so the ceiling drops to 60 s. The
     * notification keeps its state text: a countdown there was noise, and it wakes nothing.
     */
    private fun sleepBackoff() {
        var ms = backoff[backoffIndex.coerceAtMost(backoff.lastIndex)]
        if (backoffIndex < backoff.lastIndex) backoffIndex++
        // The short ceiling is for "the Mac was just opened, the phone is in my hand". It only
        // makes sense on the network the Mac was last reached on.
        if (onMacNetwork() && getSystemService(PowerManager::class.java).isInteractive) {
            ms = ms.coerceAtMost(SCREEN_ON_CEILING_MS)
        }
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
                val first = lanNetworks.isEmpty()
                lanNetworks += network
                // The loop may be parked waiting for any LAN; the flap guard must not swallow that.
                if (first) wake()
                onEvent()
            }

            override fun onLost(network: Network) {
                lanNetworks -= network
            }
        }
        netCallback = cb
        watchingNetworks = runCatching { cm.registerNetworkCallback(req, cb) }.isSuccess

        // Picking the phone up is the other event worth a dial: "Mac started later" is the
        // common case, and the user should not wait out a 300 s ceiling with the phone in hand.
        val screen = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                // Connected: a battery report held back while the screen was off goes out now.
                if (current != null) battery.flush()
                // Only where the Mac was last seen: at the office every unlock would otherwise
                // cost a SYN and an 8 s browse.
                else if (store.isPaired && store.autoConnect && onMacNetwork()) onEvent()
            }
        }
        screenReceiver = screen
        registerReceiver(screen, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        })
    }

    /**
     * Flap guard: a weak Wi-Fi link fires `onAvailable` several times in a row, and each event
     * used to restart the ladder at 1 s and dial again immediately. Once we are at the bottom of
     * the ladder, further events inside FLAP_GUARD_MS are ignored; a genuine return of the
     * network is still handled by the first one.
     */
    private fun onEvent() {
        val now = SystemClock.elapsedRealtime()
        if (backoffIndex == 0 && now - lastLadderReset < FLAP_GUARD_MS) return
        lastLadderReset = now
        restartLadder()                  // also clears macAsleep: a new network or the phone in hand
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

    /**
     * The current LAN, as "prefix/gateway" (`192.168.1.0/24/192.168.1.1`). Without the location
     * permission the Wi-Fi name is unreadable; this is the next best way to tell home from office.
     * Two networks that share both are treated as one, which is the old behaviour.
     */
    private fun networkKey(): String? {
        val lp = lanNetwork()
            ?.let { getSystemService(ConnectivityManager::class.java).getLinkProperties(it) } ?: return null
        val v4 = lp.linkAddresses.firstOrNull { it.address is java.net.Inet4Address } ?: return null
        val gateway = lp.routes.firstOrNull { it.isDefaultRoute && it.gateway is java.net.Inet4Address }
            ?.gateway?.hostAddress.orEmpty()
        return NetworkInfo.networkPrefix(v4.address.address, v4.prefixLength) + "/$gateway"
    }

    /** True while unknown too: before the first connection there is nothing to compare with. */
    private fun onMacNetwork(): Boolean {
        val known = store.macNetwork ?: return true
        return networkKey().let { it == null || it == known }
    }

    private fun note(text: String, connected: Boolean = false) {
        if (lastNote == text to connected) return
        lastNote = text to connected
        getSystemService(NotificationManager::class.java)
            .notify(FGS_ID, buildNotification(text, connected))
    }

    companion object {
        const val ACTION_PAIR = "io.github.anilmetin0.andromac.PAIR"
        const val ACTION_CONNECT = "io.github.anilmetin0.andromac.CONNECT"
        /** With [ACTION_PAIR]: the Bonjour instance name the user chose. */
        const val EXTRA_MAC = "mac"
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
        /** Pairing with no Mac picked: how long to keep listening after the first one answers. */
        private const val PAIR_SETTLE_MS = 1_500L
        /** Paired: how long to keep listening after the first Mac with our Mac's name answers. */
        private const val PAIRED_SETTLE_MS = 1_000L
        /** Repeated `onAvailable` events inside this window do not restart the ladder. */
        private const val FLAP_GUARD_MS = 10_000L
        /** The backoff ceiling while the screen is on; 300 s stays for a phone in a pocket. */
        private const val SCREEN_ON_CEILING_MS = 60_000L

        fun start(ctx: Context, action: String? = null, mac: String? = null) {
            val i = Intent(ctx, LinkService::class.java).apply {
                if (action != null) this.action = action
                if (mac != null) putExtra(EXTRA_MAC, mac)
            }
            ctx.startForegroundService(i)
        }
    }
}
