package dev.andromac.feature

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.media.AudioManager
import android.os.Handler
import android.os.HandlerThread
import android.provider.Settings
import android.util.Log
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Protocol
import org.json.JSONObject

/**
 * Ringer mode and media volume, reported to the Mac and settable from it (PROTOCOL §5 `system`,
 * `system_control`).
 *
 * These are the two things people reach across the desk for while the phone is in a bag: silence
 * it, or turn the music down. The state is pushed on connect and whenever it changes on the phone,
 * so the Mac's controls always show the phone's own answer rather than the last thing the Mac
 * asked for.
 *
 * PLATFORM CONSTRAINT — silencing needs Do Not Disturb access ([NotificationManager
 * .isNotificationPolicyAccessGranted]), a grant separate from the notification access the app
 * already asks for. Without it `setRingerMode(SILENT)` throws, so `can_silence` travels with the
 * state and the Mac disables the button instead of sending a command that can only fail.
 */
class SystemBridge(private val context: Context) {

    private val audio = context.getSystemService(AudioManager::class.java)
    private val notifications = context.getSystemService(NotificationManager::class.java)

    /**
     * Both watchers deliver on this thread, and [report] writes to the socket — a broadcast or a
     * settings change arriving on the main thread would be a `NetworkOnMainThreadException`.
     */
    private val thread = HandlerThread("andromac-system").apply { start() }
    private val handler = Handler(thread.looper)

    /** Ringer changes arrive as a broadcast; volume changes only through the settings observer. */
    private val ringerWatcher = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = report()
    }

    private val volumeWatcher = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) = report()
    }

    private var watching = false

    /** Called when the link comes up: the Mac gets the current state and every change after it. */
    fun start() {
        report()
        if (watching) return
        watching = true
        runCatching {
            context.registerReceiver(
                ringerWatcher, IntentFilter(AudioManager.RINGER_MODE_CHANGED_ACTION),
                null, handler,
            )
            // No public broadcast carries a volume change, but the value lives in Settings.System
            // and the observer fires on every step of the hardware keys.
            context.contentResolver.registerContentObserver(
                Settings.System.CONTENT_URI, true, volumeWatcher
            )
        }.onFailure { Log.i(Link.TAG, "system watchers not registered: ${it.message}") }
    }

    fun stop() {
        if (!watching) return
        watching = false
        runCatching { context.unregisterReceiver(ringerWatcher) }
        runCatching { context.contentResolver.unregisterContentObserver(volumeWatcher) }
    }

    /** Send the current ringer and volume. Cheap: one small message, only on connect or a change. */
    fun report() {
        if (!Link.isConnected) return
        Link.send(
            Protocol.system(
                ringer = ringerName(),
                volume = runCatching { audio.getStreamVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(0),
                volumeMax = runCatching { audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(0),
                canSilence = canSilence(),
            )
        )
    }

    /** One `system_control` from the Mac. Every branch reports back, so the Mac sees the result. */
    fun control(msg: JSONObject) {
        when (msg.optString("cmd")) {
            "ringer" -> setRinger(msg.optString("mode"))
            "volume" -> setVolume(msg.optInt("level", -1))
            "test_notification" -> testNotification()
            else -> return
        }
    }

    private fun setRinger(mode: String) {
        val value = when (mode) {
            "normal" -> AudioManager.RINGER_MODE_NORMAL
            "vibrate" -> AudioManager.RINGER_MODE_VIBRATE
            "silent" -> AudioManager.RINGER_MODE_SILENT
            else -> return
        }
        // Both silencing and coming back out of silence go through the Do Not Disturb policy on
        // recent Android versions, so the failure is caught rather than assumed away.
        runCatching { audio.ringerMode = value }
            .onFailure { Log.i(Link.TAG, "ringer change refused: ${it.message}") }
        report()
    }

    private fun setVolume(level: Int) {
        if (level < 0) return
        val max = runCatching { audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(0)
        runCatching { audio.setStreamVolume(AudioManager.STREAM_MUSIC, level.coerceIn(0, max), 0) }
            .onFailure { Log.i(Link.TAG, "volume change refused: ${it.message}") }
        report()
    }

    /**
     * Posts a notification to this phone and lets it travel the normal way — the listener picks it
     * up and mirrors it to the Mac ([NotificationRelay]). That is the point: it proves the whole
     * chain, so when nothing appears on the Mac the missing piece is a permission on the phone
     * rather than anything the Mac could show.
     */
    private fun testNotification() {
        notifications.createNotificationChannel(
            NotificationChannel(
                CHANNEL_TEST, context.getString(R.string.channel_test),
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        )
        notifications.notify(
            NOTIF_TEST,
            Notification.Builder(context, CHANNEL_TEST)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(context.getString(R.string.test_notification_title))
                .setContentText(context.getString(R.string.test_notification_body))
                .setAutoCancel(true)
                .setTimeoutAfter(TEST_TIMEOUT_MS)
                .build()
        )
    }

    private fun ringerName(): String = when (runCatching { audio.ringerMode }.getOrNull()) {
        AudioManager.RINGER_MODE_SILENT -> "silent"
        AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
        else -> "normal"
    }

    private fun canSilence(): Boolean =
        runCatching { notifications.isNotificationPolicyAccessGranted }.getOrDefault(false)

    companion object {
        /** The test notification's own channel: [NotificationRelay] lets our package through on it. */
        const val CHANNEL_TEST = "andromac.test"
        private const val NOTIF_TEST = 7
        /** It has done its job the moment it reaches the Mac; it should not linger in the shade. */
        private const val TEST_TIMEOUT_MS = 30_000L
    }
}
