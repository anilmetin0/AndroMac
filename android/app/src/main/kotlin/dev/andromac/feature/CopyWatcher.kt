package dev.andromac.feature

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
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
    private val read = Runnable {
        if (!Link.isConnected || !Store(this).syncClipboard) return@Runnable
        runCatching { startActivity(ClipHelperActivity.getIntent(this, quiet = true)) }
            .onFailure { Log.i(Link.TAG, "copy watcher could not take focus: ${it.message}") }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.packageName == packageName || !looksLikeCopy(event)) return
        // Writing the Mac's text makes Samsung show "Copied" too; that is not the user copying.
        if (SystemClock.elapsedRealtime() - ClipboardBridge.lastFromMacAt < 1500) return
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

    override fun onServiceConnected() = LinkService.startIfPaired(this)

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        handler.removeCallbacks(read)
        super.onDestroy()
    }

    companion object {
        /** Whether the user turned this service on in Accessibility settings. */
        fun isEnabled(ctx: Context): Boolean =
            Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
                .contains(ComponentName(ctx, CopyWatcher::class.java).flattenToString())


        // shortcut: English and Turkish words only, plus the system's own "Copy"; add a locale when someone needs it.
        private val copyWord = Regex("""(copy|kopyala)( (link|text|metni|bağlantıyı))?""")
        private val copied = Regex("""copied|kopyaland""")
    }
}
