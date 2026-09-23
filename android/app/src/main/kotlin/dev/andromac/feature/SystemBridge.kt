package dev.andromac.feature

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.media.AudioManager
import android.net.Uri
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
 * `system_control`). Also whether Wireless debugging is on, which is what the Mac's screen
 * mirroring (scrcpy over adb) needs, and a shortcut that opens that switch.
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

    /**
     * Ringer changes arrive as a broadcast; volume and Wireless debugging changes only through
     * settings observers.
     */
    private val ringerWatcher = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = report()
    }

    /**
     * `Settings.System` is observed as a whole, because the per-stream volume keys differ between
     * versions and manufacturers, but only a change to a volume key or to Wireless debugging is
     * worth the binder calls in [report]. Brightness, screen timeout and the rest are dropped here.
     */
    private val settingsWatcher = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) = report()

        override fun onChange(selfChange: Boolean, uri: Uri?) {
            val key = uri?.lastPathSegment
            if (uri == null || key == null || key.startsWith("volume") || key == ADB_WIFI_ENABLED) report()
        }
    }

    private var watching = false

    /**
     * The last state sent. The settings observer fires for every system setting (brightness,
     * screen timeout, …), so without this each of those would be a message and a radio wake-up
     * (PROTOCOL §6.13: only on a ringer, volume or debugging change).
     */
    @Volatile private var lastSent: String? = null

    /** Called when the link comes up: the Mac gets the current state and every change after it. */
    fun start() {
        lastSent = null
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
                Settings.System.CONTENT_URI, true, settingsWatcher
            )
            context.contentResolver.registerContentObserver(
                Settings.Global.getUriFor(ADB_WIFI_ENABLED), false, settingsWatcher
            )
        }.onFailure { Log.i(Link.TAG, "system watchers not registered: ${it.message}") }
    }

    /** The service is going away for good; the watcher thread goes with it. */
    fun close() {
        stop()
        thread.quitSafely()
    }

    fun stop() {
        if (!watching) return
        watching = false
        runCatching { context.unregisterReceiver(ringerWatcher) }
        runCatching { context.contentResolver.unregisterContentObserver(settingsWatcher) }
    }

    /** Send the current ringer and volume. Cheap: one small message, only on connect or a change. */
    fun report() {
        if (!Link.isConnected) return
        val msg = Protocol.system(
            ringer = ringerName(),
            volume = runCatching { audio.getStreamVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(0),
            volumeMax = runCatching { audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(0),
            canSilence = canSilence(),
            wirelessDebugging = wirelessDebugging(),
        )
        val text = msg.toString()
        if (text == lastSent) return
        if (Link.send(msg)) lastSent = text
    }

    /** One `system_control` from the Mac. Every branch reports back, so the Mac sees the result. */
    fun control(msg: JSONObject) {
        when (msg.optString("cmd")) {
            "ringer" -> setRinger(msg.optString("mode"))
            "volume" -> setVolume(msg.optInt("level", -1))
            "test_notification" -> testNotification()
            "open_debugging" -> openDebugging()
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

    /**
     * The Mac asked to mirror the screen and Wireless debugging is off. Android has no public screen
     * for that one switch, so this opens Developer options scrolled to it, the way Shizuku does, or
     * About phone when Developer options have not been unlocked yet. Starting an activity from the
     * background needs "Display over other apps"; without it the same intent rides a notification.
     */
    private fun openDebugging() {
        val unlocked = runCatching {
            Settings.Global.getInt(context.contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) == 1
        }.getOrDefault(false)
        val intent = if (unlocked) {
            Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                .putExtra(":settings:fragment_args_key", "toggle_adb_wireless")
        } else {
            Intent(Settings.ACTION_DEVICE_INFO_SETTINGS)
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        if (Settings.canDrawOverlays(context) &&
            runCatching { context.startActivity(intent) }.isSuccess
        ) return

        notifications.createNotificationChannel(
            NotificationChannel(
                CHANNEL_MIRROR, context.getString(R.string.channel_mirror),
                NotificationManager.IMPORTANCE_HIGH,
            )
        )
        val open = PendingIntent.getActivity(
            context, REQ_DEBUGGING, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        notifications.notify(
            NOTIF_DEBUGGING,
            Notification.Builder(context, CHANNEL_MIRROR)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(context.getString(R.string.mirror_debugging_title))
                .setContentText(
                    context.getString(
                        if (unlocked) R.string.mirror_debugging_body else R.string.mirror_developer_body
                    )
                )
                .setContentIntent(open)
                .setAutoCancel(true)
                .setTimeoutAfter(DEBUGGING_TIMEOUT_MS)
                .build()
        )
    }

    /** `Settings.Global.ADB_WIFI_ENABLED` is hidden but marked readable, so any app may read it. */
    private fun wirelessDebugging(): Boolean = runCatching {
        Settings.Global.getInt(context.contentResolver, ADB_WIFI_ENABLED, 0) == 1
    }.getOrDefault(false)

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

        private const val ADB_WIFI_ENABLED = "adb_wifi_enabled"
        private const val CHANNEL_MIRROR = "andromac.mirror"
        private const val NOTIF_DEBUGGING = 8
        private const val REQ_DEBUGGING = 9
        private const val DEBUGGING_TIMEOUT_MS = 120_000L
    }
}
