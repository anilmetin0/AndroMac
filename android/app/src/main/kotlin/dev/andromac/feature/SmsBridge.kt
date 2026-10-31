package dev.andromac.feature

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import dev.andromac.core.Link
import dev.andromac.core.Protocol
import dev.andromac.core.Sms
import dev.andromac.core.Store

/**
 * Messages on the Mac (PROTOCOL §5 `sms_*`): the phone's SMS conversations on request, and a text
 * sent through the phone's default SIM. Only SMS: MMS, RCS and chat apps live elsewhere.
 *
 * Nothing is pushed unasked. The Mac asks for the list or one conversation when its window opens,
 * and the phone only says `sms_changed` when the store changes, so the Mac can ask again.
 *
 * Energy (PROTOCOL §6): no timer and no polling. A content observer on the SMS provider is
 * registered only while the link is up and Messages is on; a burst of changes (one text arriving,
 * the parts of one sent) becomes one `sms_changed` after a single delayed post.
 *
 * PLATFORM CONSTRAINT — this app is not the default SMS app, so it never writes to the provider:
 * Android records what [SmsManager] sends in the phone's own Messages app by itself.
 */
class SmsBridge(context: Context, private val store: Store) {

    // The Context itself is NOT HELD IN A FIELD: [active] is static (see MediaBridge). Sending
    // borrows the caller's for the PendingIntents.
    private val resolver = context.contentResolver
    private val packages = context.packageManager
    private val pkg = context.packageName

    /** Provider queries, the observer and the coalescing post all run here, never on the main thread. */
    private val thread = HandlerThread("andromac-sms").apply { start() }
    private val handler = Handler(thread.looper)

    private var connected = false
    private var watching = false
    private var changePending = false
    /** The state at the last [apply]; a change of it is what the Mac hears about. */
    private var lastState: String? = null

    /**
     * Sends waiting for the radio, by the first part's request code: the Mac's ids are not
     * guaranteed unique. Kept across a link drop, so a result after a quick reconnect still goes.
     */
    private val sending = HashMap<Int, Pair<String, Sms.Parts>>()

    private val observer = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) = changed()
        override fun onChange(selfChange: Boolean, uri: Uri?) = changed()
    }

    private val notify = Runnable {
        changePending = false
        if (watching) Link.send(Protocol.smsChanged())
    }

    /** When the link comes up. Called from the service thread. */
    fun start() {
        handler.post {
            active = this
            connected = true
            apply()
        }
    }

    /** When the link drops: the observer goes. A send result that arrives meanwhile is dropped by [Link.send]. */
    fun stop() {
        handler.post {
            connected = false
            apply()
        }
    }

    /** The service is going away for good. */
    fun close() {
        handler.post {
            if (active === this) active = null
            connected = false
            apply()
            thread.quitSafely()
        }
    }

    /** `sms_request`: [threadId] null for the conversation list. Called from the read thread. */
    fun request(threadId: Long?) {
        handler.post {
            val state = state()
            when {
                threadId == null && state != Sms.STATE_OK -> Link.send(Protocol.smsThreads(state))
                threadId == null -> Link.send(threads())
                state != Sms.STATE_OK -> Link.send(Protocol.smsMessages(threadId, state))
                else -> Link.send(messages(threadId))
            }
        }
    }

    /** `sms_send`. Exactly one `sms_sent` answers it, now on a refusal, else when the radio reports. */
    fun send(ctx: Context, id: String, to: String, body: String) {
        val app = ctx.applicationContext
        handler.post {
            val refusal = when {
                !Sms.validId(id) -> Sms.REASON_INVALID
                !store.sms -> Sms.REASON_OFF
                !granted(Manifest.permission.SEND_SMS) -> Sms.REASON_NO_PERMISSION
                !Sms.validTo(to) || !Sms.validBody(body) -> Sms.REASON_INVALID
                // A Wi-Fi tablet installs (the manifest does not require telephony) but has no radio.
                !packages.hasSystemFeature(PackageManager.FEATURE_TELEPHONY_MESSAGING) -> Sms.REASON_NO_SERVICE
                else -> null
            }
            if (refusal != null) {
                Link.send(Protocol.smsSent(id, false, refusal))
                return@post
            }
            dispatch(app, id, to, body)
        }
    }

    // ---------------------------------------------------------------- state

    private fun state(): String = when {
        !store.sms -> Sms.STATE_OFF
        !granted(Manifest.permission.READ_SMS) -> Sms.STATE_NO_PERMISSION
        else -> Sms.STATE_OK
    }

    /**
     * Observe exactly while connected, on and allowed. Handler thread only. With [tellMac], a
     * switch or a grant may have changed the state on a live link: `sms_changed` makes an open
     * Messages page ask again, and see the list or the new `off` / `no_permission`.
     */
    private fun apply(tellMac: Boolean = false) {
        val state = state()
        if (tellMac && connected && lastState != null && state != lastState) Link.send(Protocol.smsChanged())
        lastState = state
        val want = connected && state == Sms.STATE_OK
        if (want == watching) return
        if (want) {
            watching = runCatching {
                resolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, observer)
            }.onFailure { Log.i(Link.TAG, "sms observer not registered: ${it.message}") }.isSuccess
        } else {
            watching = false
            runCatching { resolver.unregisterContentObserver(observer) }
            handler.removeCallbacks(notify)
            changePending = false
        }
    }

    /** One `sms_changed` per second at most: the first change arms one delayed post, the rest ride it. */
    private fun changed() {
        if (!watching || changePending) return
        changePending = true
        handler.postDelayed(notify, CHANGED_COALESCE_MS)
    }

    // ---------------------------------------------------------------- reading

    private fun threads(): org.json.JSONObject = runCatching {
        val collector = Sms.ThreadCollector()
        // Pass one: two integer columns, newest first, until 50 threads are in.
        resolver.query(
            Telephony.Sms.CONTENT_URI, arrayOf(Telephony.Sms.THREAD_ID, Telephony.Sms._ID),
            "${Telephony.Sms.TYPE} != ${Sms.TYPE_DRAFT}", null, "${Telephony.Sms.DATE} DESC",
        )?.use { c ->
            while (c.moveToNext() && collector.add(c.getLong(0), c.getLong(1))) Unit
        }
        // Pass two: the full row of each thread's latest message, at most 50.
        val ids = collector.rowIds()
        val rows = HashMap<Long, Sms.Row>()
        if (ids.isNotEmpty()) resolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE),
            "${Telephony.Sms._ID} IN (${ids.joinToString(",") { "?" }})", ids.map(Long::toString).toTypedArray(), null,
        )?.use { c ->
            while (c.moveToNext()) rows[c.getLong(0)] = Sms.Row(c.getString(1).orEmpty(), c.getString(2).orEmpty(), c.getLong(3))
        }
        val unread = HashMap<Long, Int>()
        resolver.query(
            Telephony.Sms.Inbox.CONTENT_URI, arrayOf(Telephony.Sms.THREAD_ID),
            "${Telephony.Sms.READ} = 0", null, null,
        )?.use { c ->
            while (c.moveToNext()) c.getLong(0).let { unread[it] = (unread[it] ?: 0) + 1 }
        }
        val names = Names(resolver, granted(Manifest.permission.READ_CONTACTS))
        Protocol.smsThreads(Sms.STATE_OK, collector.threads(rows, unread, names::lookup))
    }.getOrElse {
        // The spec has no failure state: anything but a refused permission reads as an empty list.
        Log.w(Link.TAG, "sms threads unreadable", it)
        Protocol.smsThreads(if (it is SecurityException) Sms.STATE_NO_PERMISSION else Sms.STATE_OK)
    }

    private fun messages(threadId: Long): org.json.JSONObject = runCatching {
        val collector = Sms.MessageCollector()
        resolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE),
            "${Telephony.Sms.THREAD_ID} = ?", arrayOf(threadId.toString()), "${Telephony.Sms.DATE} DESC",
        )?.use { c ->
            while (c.moveToNext() && collector.add(c.getLong(0), c.getString(1).orEmpty(), c.getLong(2), c.getInt(3))) Unit
        }
        Protocol.smsMessages(threadId, Sms.STATE_OK, collector.messages())
    }.getOrElse {
        Log.w(Link.TAG, "sms messages unreadable", it)
        Protocol.smsMessages(threadId, if (it is SecurityException) Sms.STATE_NO_PERMISSION else Sms.STATE_OK)
    }

    /** Contact names, only with Contacts access, each number looked up once per request. */
    private class Names(private val resolver: ContentResolver, private val allowed: Boolean) {
        private val cache = HashMap<String, String?>()

        fun lookup(addr: String): String? {
            if (!allowed || addr.isBlank()) return null
            return cache.getOrPut(addr) {
                runCatching {
                    resolver.query(
                        Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(addr)),
                        arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null,
                    )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
                }.getOrNull()?.takeIf { it.isNotBlank() }
            }
        }
    }

    // ---------------------------------------------------------------- sending

    /** Runtime grants included: the package manager answers for this app as it stands now. */
    private fun granted(permission: String): Boolean =
        packages.checkPermission(permission, pkg) == PackageManager.PERMISSION_GRANTED

    private fun dispatch(app: Context, id: String, to: String, body: String) {
        // Every part gets a request code of its own, from a counter kept across restarts.
        val key = store.smsRequestCode
        val result = runCatching {
            val manager = if (Build.VERSION.SDK_INT >= 31) app.getSystemService(SmsManager::class.java)
            else @Suppress("DEPRECATION") SmsManager.getDefault()
            val parts = manager.divideMessage(body)
            store.smsRequestCode = (key + parts.size).let { if (it < 0 || it > MAX_REQUEST_CODE) 0 else it }
            sending[key] = id to Sms.Parts(parts.size)
            // One result per part, each its own PendingIntent: a shared one would collapse into one.
            val sent = ArrayList(parts.indices.map { part ->
                PendingIntent.getBroadcast(
                    app, key + part,
                    Intent(app, SmsSentReceiver::class.java).putExtra(EXTRA_KEY, key),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_ONE_SHOT,
                )
            })
            manager.sendMultipartTextMessage(to, null, parts, sent, null)
        }
        result.exceptionOrNull()?.let {
            Log.i(Link.TAG, "sms not sent: ${it.message}")
            sending.remove(key)
            Link.send(Protocol.smsSent(id, false, if (it is SecurityException) Sms.REASON_NO_PERMISSION else Sms.REASON_FAILED))
        }
    }

    private fun partSent(key: Int, resultCode: Int) {
        val (id, parts) = sending[key] ?: return
        val failure = when (resultCode) {
            Activity.RESULT_OK -> null
            SmsManager.RESULT_ERROR_NO_SERVICE, SmsManager.RESULT_ERROR_RADIO_OFF -> Sms.REASON_NO_SERVICE
            else -> Sms.REASON_FAILED
        }
        if (!parts.report(failure)) return
        sending.remove(key)
        Link.send(Protocol.smsSent(id, parts.reason == null, parts.reason))
    }

    /** The radio's verdict on one part. Only our own PendingIntents reach it (not exported). */
    class SmsSentReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val key = intent.getIntExtra(EXTRA_KEY, -1)
            val code = resultCode
            val bridge = active ?: return
            bridge.handler.post { bridge.partSent(key, code) }
        }
    }

    companion object {
        private const val CHANGED_COALESCE_MS = 1_000L
        private const val EXTRA_KEY = "key"
        /** Where the request code counter wraps; billions of parts away from ever mattering. */
        private const val MAX_REQUEST_CODE = Int.MAX_VALUE - 1_000

        /** The settings screen and the sent receiver have no handle on the link; this is how they find it. */
        @Volatile
        private var active: SmsBridge? = null

        /** Messages was turned on or off, or a permission changed: apply it to a live link now. */
        fun settingChanged() {
            val bridge = active ?: return
            bridge.handler.post { bridge.apply(tellMac = true) }
        }
    }
}
