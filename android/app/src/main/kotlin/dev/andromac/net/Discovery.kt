package dev.andromac.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import dev.andromac.core.Link
import java.net.InetAddress
import java.util.ArrayDeque
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

/**
 * mDNS discovery for `_andromac._tcp`. PROTOCOL §1.
 *
 * Energy: the scan runs ONLY while we are unable to connect, and for at most [TIMEOUT_MS].
 * Once the link is up the caller invokes [stop]. A continuous mDNS scan costs measurable
 * battery.
 */
class Discovery(context: Context) {

    private val app = context.applicationContext
    private val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = app.getSystemService(Context.WIFI_SERVICE) as WifiManager

    data class Peer(val host: InetAddress, val port: Int, val name: String)

    private var listener: NsdManager.DiscoveryListener? = null
    private var lock: WifiManager.MulticastLock? = null

    /** The first peer resolved this round; [findOne] blocks on it. */
    private val found = ArrayBlockingQueue<Peer>(1)

    /**
     * API 29-33 only: NsdManager resolves ONE service at a time. A second concurrent
     * `resolveService` fails with `FAILURE_ALREADY_ACTIVE` and is never retried, so a
     * neighbour's instance could burn the whole window. Resolves are queued and run in turn.
     */
    private val queued = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    /**
     * The live API 34+ callbacks, so [stop] can unregister every one of them — a callback left
     * registered keeps mDNS traffic going after the link is up. Typed as [Any] on purpose:
     * `NsdManager.ServiceInfoCallback` does not exist below API 34, and the only places that
     * name it are guarded by a version check.
     */
    private val watchers = ArrayList<Any>()

    /** Callbacks may run on the system's own thread; everything they touch is thread-safe. */
    private val direct = Executor { it.run() }

    /** Blocking. Returns the first peer found, or null if none appears within [TIMEOUT_MS]. */
    fun findOne(): Peer? {
        found.clear()
        synchronized(this) { queued.clear(); resolving = false }
        // On some devices mDNS multicast packets are filtered out without this lock.
        lock = wifi.createMulticastLock("andromac-mdns").apply { setReferenceCounted(false); acquire() }

        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(t: String) = Unit
            override fun onDiscoveryStopped(t: String) = Unit
            override fun onStartDiscoveryFailed(t: String, code: Int) {
                Log.w(Link.TAG, "could not start discovery: $code")
            }
            override fun onStopDiscoveryFailed(t: String, code: Int) = Unit

            override fun onServiceFound(info: NsdServiceInfo) {
                if (Build.VERSION.SDK_INT >= 34) watch(info) else enqueue(info)
            }

            override fun onServiceLost(info: NsdServiceInfo) = Unit
        }

        listener = l
        return try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
            found.poll(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (e: Exception) {
            Log.w(Link.TAG, "discovery error", e); null
        } finally {
            stop()
        }
    }

    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        unwatchAll()
        synchronized(this) { queued.clear() }
        lock?.let { runCatching { it.release() } }
        lock = null
    }

    private fun nameOf(info: NsdServiceInfo): String =
        info.attributes["n"]?.toString(Charsets.UTF_8) ?: info.serviceName

    // ---------------------------------------------------------------- API 34+

    /**
     * `registerServiceInfoCallback` replaced the deprecated one-at-a-time `resolveService`:
     * it resolves and keeps tracking, and several may run at once.
     */
    private fun watch(info: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT < 34) return
        val cb = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                Log.w(Link.TAG, "could not track the service: $errorCode")
            }

            override fun onServiceUpdated(serviceInfo: NsdServiceInfo) {
                serviceInfo.hostAddresses.firstOrNull()?.let {
                    found.offer(Peer(it, serviceInfo.port, nameOf(serviceInfo)))
                }
            }

            override fun onServiceLost() = Unit
            override fun onServiceInfoCallbackUnregistered() = Unit
        }
        synchronized(this) { watchers += cb }
        runCatching { nsd.registerServiceInfoCallback(info, direct, cb) }
    }

    private fun unwatchAll() {
        if (Build.VERSION.SDK_INT < 34) return
        val open = synchronized(this) { watchers.toList().also { watchers.clear() } }
        open.forEach { cb ->
            runCatching { nsd.unregisterServiceInfoCallback(cb as NsdManager.ServiceInfoCallback) }
        }
    }

    // ---------------------------------------------------------------- API 29-33

    private fun enqueue(info: NsdServiceInfo) {
        synchronized(this) { queued.add(info) }
        resolveNext()
    }

    @Suppress("DEPRECATION")      // resolveService and NsdServiceInfo.host, replaced above on 34+
    private fun resolveNext() {
        val info = synchronized(this) {
            if (resolving) return
            val next = queued.poll() ?: return
            resolving = true
            next
        }
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(i: NsdServiceInfo, code: Int) {
                Log.w(Link.TAG, "resolve failed: $code")
                resolveDone()
            }

            override fun onServiceResolved(i: NsdServiceInfo) {
                i.host?.let { found.offer(Peer(it, i.port, nameOf(i))) }
                resolveDone()
            }
        })
    }

    private fun resolveDone() {
        synchronized(this) { resolving = false }
        resolveNext()
    }

    companion object {
        const val SERVICE_TYPE = "_andromac._tcp."
        const val TIMEOUT_MS = 8_000L
    }
}
