package io.github.anilmetin0.andromac.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import io.github.anilmetin0.andromac.core.Link
import io.github.anilmetin0.andromac.core.MacPick.Peer
import java.net.InetAddress
import java.util.ArrayDeque
import java.util.concurrent.Executor
import java.util.concurrent.Semaphore
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

    private var listener: NsdManager.DiscoveryListener? = null
    private var lock: WifiManager.MulticastLock? = null

    /** Every Mac resolved this round, by instance name; [browse] wakes on each new one. */
    private val found = LinkedHashMap<String, Peer>()
    private val resolved = Semaphore(0)

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

    /**
     * Blocking. Browses until [enough] holds for the Macs resolved so far, then [settleMs] more
     * so a second Mac answering right behind the first is seen too, or until [TIMEOUT_MS].
     * Returns every Mac resolved in that window.
     */
    fun browse(settleMs: Long = 0, enough: (List<Peer>) -> Boolean): List<Peer> {
        synchronized(this) { found.clear(); queued.clear(); resolving = false }
        resolved.drainPermits()
        Link.setDiscovered { emptyMap() }
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
                // The instance name is the Mac's name (Server.swift advertises deviceName).
                Link.setDiscovered { if (info.serviceName in it) it else it + (info.serviceName to info.serviceName) }
                if (Build.VERSION.SDK_INT >= 34) watch(info) else enqueue(info)
            }

            override fun onServiceLost(info: NsdServiceInfo) = Unit
        }

        listener = l
        return try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS)
            var until = deadline
            while (true) {
                val left = until - System.nanoTime()
                if (left <= 0) break
                resolved.tryAcquire(left, TimeUnit.NANOSECONDS)
                if (until == deadline && enough(peers())) {
                    if (settleMs <= 0) break
                    until = minOf(deadline, System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(settleMs))
                }
            }
            peers()
        } catch (e: Exception) {
            Log.w(Link.TAG, "discovery error", e); peers()
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

    private fun peers(): List<Peer> = synchronized(this) { found.values.toList() }

    /** A re-resolve of a known Mac (a new address) replaces it and wakes nobody. */
    private fun offer(host: InetAddress, info: NsdServiceInfo) {
        val name = nameOf(info)
        val fresh = synchronized(this) {
            found.put(info.serviceName, Peer(host, info.port, info.serviceName, name)) == null
        }
        Link.setDiscovered { it + (info.serviceName to name) }
        if (fresh) resolved.release()
    }

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
                serviceInfo.hostAddresses.firstOrNull()?.let { offer(it, serviceInfo) }
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
                i.host?.let { offer(it, i) }
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
