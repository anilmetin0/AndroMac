package dev.andromac.feature

import android.app.Notification
import android.app.NotificationManager
import android.app.KeyguardManager
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import dev.andromac.core.Link
import dev.andromac.core.Protocol
import dev.andromac.core.Store

/**
 * The notification mirror. Fully event-driven — no polling (PROTOCOL §6.3).
 * The system already wakes this service when a notification arrives, so the extra battery
 * cost is close to zero.
 */
class NotificationRelay : NotificationListenerService() {

    private lateinit var store: Store
    private val keyguard: KeyguardManager by lazy { getSystemService(KeyguardManager::class.java) }

    override fun onCreate() {
        super.onCreate()
        store = Store(this)
    }

    override fun onListenerConnected() {
        instance = this
        pushExisting()
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
        // After an app update, or after an OEM kills the service, the system does not rebind
        // on its own; without asking for it the mirror silently stops working.
        runCatching { requestRebind(ComponentName(this, NotificationRelay::class.java)) }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!store.syncNotifications) return
        schedule(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (!store.syncNotifications) return
        cancelPending(sbn.key)
        // Do not send a removal for a notification we never sent (app turned off, silent,
        // lock filter): the Mac has no counterpart for it and it would wake the radio for nothing.
        if (lastSent.remove(sbn.key) == null) return
        Link.send(Protocol.notificationRemove(sbn.key))
    }

    /**
     * Delays the send by [COALESCE_MS]. Apps can update one notification several times per
     * second (download percentage, typing indicator); repeats that land inside this window
     * collapse into a single send, and ones removed inside it are never sent. Saves both
     * noise and radio time.
     */
    private fun schedule(sbn: StatusBarNotification, forceSilent: Boolean = false) {
        cancelPending(sbn.key)
        val task = Runnable {
            pending.remove(sbn.key)
            send(sbn, forceSilent)
        }
        pending[sbn.key] = task
        handler.postDelayed(task, COALESCE_MS)
    }

    private fun cancelPending(key: String) {
        pending.remove(key)?.let(handler::removeCallbacks)
    }

    private fun send(sbn: StatusBarNotification, forceSilent: Boolean = false) {
        if (!isRelayable(sbn)) return

        // Record the app BEFORE the silence filter. Otherwise an app that only ever posts
        // silent notifications would never appear on the filter screen and the user could not
        // find it to turn it on. Structural noise (group summaries, ongoing) is still not listed.
        val label = packageManager.appLabel(sbn.packageName)
        store.recordApp(sbn.packageName, label)

        // Earliest point that still records the app: nothing below this line can produce a
        // message, so with no Mac present a notification costs only the two lines above.
        if (!Link.isConnected) return

        val mode = store.modeFor(sbn.packageName)
        if (mode == Store.MODE_OFF) return
        if (!store.syncSilentNotifications &&
            importanceOf(sbn) < NotificationManager.IMPORTANCE_DEFAULT
        ) {
            return
        }

        // "Only when locked": there is no point seeing the same notification again on the Mac
        // while looking at the phone. With the screen off, the keyguard counts as locked.
        if (store.onlyWhenLocked && !keyguard.isKeyguardLocked) return

        val n = sbn.notification
        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (title.isEmpty() && text.isEmpty()) return

        // The same content was posted again: send it, but raise no sound or banner on macOS.
        val signature = "$title\u0000$text"
        val unchanged = lastSent.put(sbn.key, signature) == signature

        val actions = n.actions.orEmpty().map {
            Protocol.Action(
                title = it.title?.toString().orEmpty(),
                reply = it.remoteInputs?.isNotEmpty() == true,
            )
        }

        // TITLE_ONLY: the content NEVER LEAVES the phone. The redaction happens here, not on the Mac.
        val redacted = mode == Store.MODE_TITLE_ONLY

        Link.send(
            Protocol.notification(
                id = sbn.key,
                app = label,
                pkg = sbn.packageName,
                title = if (redacted) "" else title,
                text = if (redacted) "" else text,
                silent = forceSilent || unchanged ||
                    importanceOf(sbn) < NotificationManager.IMPORTANCE_DEFAULT,
                redacted = redacted,
                actions = if (redacted) emptyList() else actions,
            )
        )
    }

    /** Structural filter: this notification is never mirrored under any setting. */
    private fun isRelayable(sbn: StatusBarNotification): Boolean {
        // Our own notifications stay here — except the test one, whose entire purpose is to travel
        // this path and prove the listener works (SystemBridge).
        if (sbn.packageName == packageName && sbn.notification.channelId != SystemBridge.CHANNEL_TEST) {
            return false
        }
        val flags = sbn.notification.flags
        // FLAG_LOCAL_ONLY: an app sets it to say "do not carry this to another device".
        val noisy = Notification.FLAG_GROUP_SUMMARY or
            Notification.FLAG_ONGOING_EVENT or
            Notification.FLAG_FOREGROUND_SERVICE or
            Notification.FLAG_LOCAL_ONLY
        if (flags and noisy != 0) return false
        if (!sbn.isClearable) return false
        if (sbn.packageName in DISABLED_BY_DEFAULT) return false
        return true
    }

    /**
     * Channel importance; assume DEFAULT when it cannot be read (do not filter).
     *
     * The noise filter looks at CHANNEL IMPORTANCE, not at flags. Verified on device:
     * Samsung's "1 more notification" overflow entry arrives with `flags=0` — no flag filter
     * catches it — but its channel is IMPORTANCE_LOW. `Notification.priority` is not used:
     * it has been deprecated since API 26 and returns 0 for that notification.
     */
    private fun importanceOf(sbn: StatusBarNotification): Int {
        val ranking = Ranking()
        return if (currentRanking?.getRanking(sbn.key, ranking) == true) ranking.importance
        else NotificationManager.IMPORTANCE_DEFAULT
    }

    private val handler = Handler(Looper.getMainLooper())
    private val pending = HashMap<String, Runnable>()
    private val lastSent = HashMap<String, String>()

    companion object {
        private const val COALESCE_MS = 50L

        /**
         * Packages that are off by default. The user can enable them from the filter screen.
         * The Google search box re-posts its notification every few minutes.
         */
        private val DISABLED_BY_DEFAULT = setOf(
            "com.google.android.googlequicksearchbox",
        )

        @Volatile
        private var instance: NotificationRelay? = null

        /**
         * Push the notifications currently on screen once, when the link comes up.
         * They all go out as `silent` — otherwise the Mac would get a burst of pop-ups the
         * instant it connects.
         */
        fun pushExisting() {
            val self = instance ?: return
            if (!Link.isConnected || !self.store.syncNotifications) return
            // Called from the link thread. [lastSent] and [pending] must only be touched from
            // the main thread, otherwise the HashMap corrupts under concurrent modification.
            self.handler.post {
                if (!Link.isConnected) return@post
                AppModeSync.push(self.store)
                runCatching { self.activeNotifications }.getOrNull()
                    ?.forEach { self.send(it, forceSilent = true) }
            }
        }

        /** A mode change coming from the Mac. */
        fun applyMode(pkg: String, mode: Int) {
            val self = instance ?: return
            if (pkg.isEmpty() || mode !in Store.MODE_OFF..Store.MODE_FULL) return
            self.store.setMode(pkg, mode)
            AppModeSync.push(self.store)
        }

        /** An action trigger coming from the Mac. */
        fun runAction(key: String, index: Int, reply: String?) {
            val self = instance ?: return
            if (index < 0) return
            val sbn = self.find(key) ?: return
            val action = sbn.notification.actions?.getOrNull(index) ?: return
            try {
                val inputs = action.remoteInputs
                if (reply != null && inputs != null && inputs.isNotEmpty()) {
                    val intent = Intent()
                    val bundle = Bundle().apply { inputs.forEach { putCharSequence(it.resultKey, reply) } }
                    RemoteInput.addResultsToIntent(inputs, intent, bundle)
                    action.actionIntent.send(self, 0, intent)
                } else {
                    action.actionIntent.send()
                }
            } catch (e: Exception) {
                Log.w(Link.TAG, "notification action failed", e)
            }
        }

        /** Dismissed on the Mac — dismiss it on the phone too. */
        fun dismiss(key: String) {
            runCatching { instance?.cancelNotification(key) }
        }
    }

    private fun find(key: String): StatusBarNotification? =
        runCatching { activeNotifications }.getOrNull()?.firstOrNull { it.key == key }
}
