package dev.andromac.feature

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Protocol
import dev.andromac.core.Store
import dev.andromac.net.LinkService
import dev.andromac.ui.ClipHelperActivity

/**
 * The clipboard bridge.
 *
 * PLATFORM CONSTRAINT — on Android 10 (API 29) and above an app CANNOT READ the clipboard
 * unless it is focused or is the default keyboard (`getPrimaryClip()` returns null and
 * logcat shows "Denying clipboard access"). This is not a bug but a deliberate privacy
 * decision, and there is no supported way around it.
 *
 * Hence:
 *  - Phone -> Mac  : user-triggered. Either the Quick Settings tile or the share sheet.
 *    The tile opens a transparent activity that takes focus ([ClipHelperActivity]); the
 *    share sheet sends the text directly without touching the clipboard at all (the
 *    cleanest path).
 *  - Mac -> Phone  : `setPrimaryClip` is attempted, and a silent notification carrying a
 *    "Paste" action is posted as well; that action writes through the focused activity.
 *    Both routes are kept because the write restriction varies by manufacturer.
 */
class ClipboardBridge(private val context: Context, private val store: Store) {

    private val cm = context.getSystemService(ClipboardManager::class.java)

    /** Clipboard content arriving from the Mac. Called from the service thread. */
    fun receiveFromMac(raw: String) {
        // PROTOCOL §8 forbids assuming the sender truncated. Unclamped, a frame up to the
        // 1 MiB limit would cross Binder into system_server and throw, dropping the session.
        val text = raw.take(Protocol.MAX_CLIPBOARD)
        if (text.isEmpty() || !store.syncClipboard) return
        lastFromMac = text

        if (store.clipboardAutoPaste) {
            runCatching { cm.setPrimaryClip(ClipData.newPlainText("AndroMac", text)) }
                .onFailure { Log.i(Link.TAG, "direct clipboard write denied: ${it.message}") }
        }
        if (store.clipboardNotify || !store.clipboardAutoPaste) {
            notifyPastable(text)
        }
    }

    /** Called from the focused [ClipHelperActivity] — reads the clipboard and sends it to the Mac. */
    fun sendCurrentClip(): Boolean {
        if (!store.syncClipboard) return false
        val clip = cm.primaryClip?.takeIf { it.itemCount > 0 } ?: return false

        if (sensitiveBlocked(clip.description)) return false

        val text = clip.getItemAt(0).coerceToText(context)?.toString().orEmpty()
        if (text.isEmpty()) return false
        if (text == lastFromMac) return false          // break the echo
        return Link.send(Protocol.clipboard(text))
    }

    /**
     * Text arriving from the share sheet — without touching the clipboard at all. The share
     * intent carries the originating [ClipDescription] when there is one, so a password
     * manager's "share" reaches the same sensitivity check as a copy.
     */
    fun sendText(text: String, description: ClipDescription? = null): Boolean {
        if (text.isEmpty() || !store.syncClipboard) return false
        if (sensitiveBlocked(description)) return false
        return Link.send(Protocol.clipboard(text))
    }

    /**
     * Password managers and OTP fields set `EXTRA_IS_SENSITIVE` when copying (API 33+). Older
     * versions carry no such marker; there we rely on the user's own choice. Both outbound
     * paths run through here so the exported share-sheet target cannot bypass the toggle.
     */
    private fun sensitiveBlocked(description: ClipDescription?): Boolean {
        if (!store.clipboardSkipSensitive) return false
        val sensitive = Build.VERSION.SDK_INT >= 33 &&
            description?.extras?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE) == true
        if (sensitive) Log.i(Link.TAG, "sensitive clipboard content not sent")
        return sensitive
    }

    private fun notifyPastable(text: String) {
        val paste = PendingIntent.getActivity(
            context, 2,
            ClipHelperActivity.putIntent(context, text),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val title = context.getString(R.string.clip_incoming_title)
        // The content is NOT SHOWN on the lock screen: the incoming text may be a password or
        // an OTP. The public version carries only the title; the full text appears once unlocked.
        val public = Notification.Builder(context, LinkService.CHANNEL_CLIP)
            .setSmallIcon(R.drawable.ic_clipboard)
            .setContentTitle(title)
            .build()
        val n = Notification.Builder(context, LinkService.CHANNEL_CLIP)
            .setSmallIcon(R.drawable.ic_clipboard)
            .setContentTitle(title)
            .setContentText(text.lineSequence().first().take(120))
            .setStyle(Notification.BigTextStyle().bigText(text.take(400)))
            .setContentIntent(paste)
            .addAction(
                Notification.Action.Builder(
                    null as android.graphics.drawable.Icon?,
                    context.getString(R.string.clip_paste_action), paste,
                ).build()
            )
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setAutoCancel(true)
            .build()
        context.getSystemService(NotificationManager::class.java).notify(CLIP_NOTIF_ID, n)
    }

    companion object {
        private const val CLIP_NOTIF_ID = 2

        /** Echo breaker: never send text that came from the Mac back to the Mac. */
        @Volatile
        var lastFromMac: String? = null
    }
}
