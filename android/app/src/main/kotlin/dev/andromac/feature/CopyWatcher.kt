package dev.andromac.feature

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import dev.andromac.R
import android.content.Context
import android.provider.Settings
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import dev.andromac.core.Link
import dev.andromac.core.Store
import dev.andromac.net.LinkService
import dev.andromac.ui.ClipHelperActivity

/**
 * Notices a copy on the phone so it reaches the Mac without the user asking.
 *
 * Android 10+ still lets no background app read the clipboard, this service included. It only
 * sees that a copy probably happened: a tap on a "Copy" button, Android 13+'s "Copied" overlay, or
 * an app's "Copied" toast. Then the invisible [ClipHelperActivity] takes focus for a moment and
 * reads it, the same path the Mac's request uses. A bound accessibility service is allowed to
 * start that activity from the background. It reads no window content (see the config xml).
 */
class CopyWatcher : AccessibilityService() {

    private val handler = Handler(Looper.getMainLooper())
    /** When the helper last read the clipboard. */
    private var lastRead = 0L

    private val read = Runnable {
        if (!Link.isConnected || !Store(this).syncClipboard) return@Runnable
        lastRead = SystemClock.elapsedRealtime()
        runCatching { startActivity(ClipHelperActivity.getIntent(this, quiet = true)) }
            .onFailure { Log.i(Link.TAG, "copy watcher could not take focus: ${it.message}") }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.packageName == packageName || !looksLikeCopy(event)) return
        // A tap on Copy is the user. A "Copied" toast or overlay also follows every clipboard
        // write, the Mac's and the copy just read included, up to 4.4 s later on a Galaxy S24
        // (Link to Windows: "Copied to your connected devices"). Reading again would take focus
        // from whatever the user is doing, so those signals wait out a quiet period.
        val now = SystemClock.elapsedRealtime()
        if (event.eventType != AccessibilityEvent.TYPE_VIEW_CLICKED &&
            now - maxOf(lastRead, ClipboardBridge.lastFromMacAt) < QUIET_MS
        ) return
        // Which signal fired, never what it said: enough to tell a missed copy from a stray read.
        Log.i(Link.TAG, "copy watcher: ${AccessibilityEvent.eventTypeToString(event.eventType)} from ${event.packageName}")
        // The app writes the clip right after the tap; a burst of events is one read.
        handler.removeCallbacks(read)
        handler.postDelayed(read, 250)
    }

    private fun looksLikeCopy(event: AccessibilityEvent): Boolean {
        // Chrome's toolbar sends the label twice, as text and as description: each is checked alone.
        val words = (event.text + listOfNotNull(event.contentDescription)).map { it.toString().lowercase().trim() }
        val copyLabel = getString(android.R.string.copy).lowercase()
        val systemUi = event.packageName == "com.android.systemui"
        return when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> words.any { it.matches(copyWord) || it == copyLabel }
            // Android 13+'s "Copied" overlay (window ClipboardOverlay) reports only a bare FrameLayout;
            // SystemUI's other windows (volume, shade) name their own class.
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ->
                systemUi && event.className == "android.widget.FrameLayout"
            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED ->
                event.className?.contains("Toast") == true && words.any { copied.containsMatchIn(it) }
            else -> false
        }
    }

    override fun onServiceConnected() {
        running = true
        getSystemService(NotificationManager::class.java).cancel(STUCK_ID)
        LinkService.startIfPaired(this)
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        running = false
        // Still on in Settings means Android dropped it, not the user: on a Galaxy S24 (Android
        // 17) it unbound this and another sideloaded app's service at once, with no update.
        val app = applicationContext
        if (isEnabled(app)) Handler(Looper.getMainLooper()).postDelayed({ warnIfStuck(app) }, 10_000)
        handler.removeCallbacks(read)
        super.onDestroy()
    }

    companion object {
        private const val QUIET_MS = 8_000L
        private const val STUCK_ID = 12

        /** True while Android has this service bound in this process. */
        @Volatile
        var running = false
            private set

        /**
         * On in Settings but not bound. After an app update a Galaxy S24 (Android 17) left the
         * service like this every time; only turning it off and on again in Settings brings it
         * back, and the app cannot do that itself.
         */
        fun isStuck(ctx: Context): Boolean = isEnabled(ctx) && !running

        /** Tell the user, after giving Android time to bind it again on its own. */
        fun warnIfStuck(ctx: Context) {
            if (!isStuck(ctx)) return
            val open = PendingIntent.getActivity(
                ctx, STUCK_ID, Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val n = Notification.Builder(ctx, LinkService.CHANNEL_CLIP)
                .setSmallIcon(R.drawable.ic_clipboard)
                .setContentTitle(ctx.getString(R.string.copy_watcher_stuck_title))
                .setContentText(ctx.getString(R.string.copy_watcher_stuck_body))
                .setStyle(Notification.BigTextStyle().bigText(ctx.getString(R.string.copy_watcher_stuck_body)))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build()
            ctx.getSystemService(NotificationManager::class.java).notify(STUCK_ID, n)
        }

        /** Whether the user turned this service on in Accessibility settings. */
        fun isEnabled(ctx: Context): Boolean =
            Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
                .contains(ComponentName(ctx, CopyWatcher::class.java).flattenToString())


        // shortcut: English and Turkish words only, plus the system's own "Copy"; add a locale when someone needs it.
        private val copyWord = Regex("""(copy|kopyala)( (link|text|metni|bağlantıyı))?""")
        private val copied = Regex("""copied|kopyaland""")
    }
}
