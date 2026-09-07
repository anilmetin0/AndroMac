package dev.andromac.feature

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Store
import dev.andromac.ui.MainActivity

/**
 * "Find phone": a single `find_phone` message arrives from the Mac and the phone sounds off.
 *
 * Energy (PROTOCOL §6.11): the Mac never sends a "stop". The phone silences itself after
 * 30 s through one [Handler.postDelayed] — no periodic timer. A second `find_phone` also
 * silences it; pressing the button again on the Mac is the only remote way to stop it.
 *
 * A full-screen intent (`setFullScreenIntent`) is deliberately absent: since API 34 the
 * system demotes it to a banner for ordinary apps and it also requires a separate
 * permission. A high-priority notification plus the alarm sound does the same job.
 */
object FindPhone {

    private val handler = Handler(Looper.getMainLooper())

    @Volatile
    private var running = false
    private var ringtone: Ringtone? = null
    private var timeout: Runnable? = null

    /** Called from LinkService's read thread; sound and vibration are moved to the main thread. */
    fun start(ctx: Context) {
        val app = ctx.applicationContext
        handler.post { if (running) end(app) else begin(app) }
    }

    /** "Found it", swiping the notification away, opening the app, or the link dropping. */
    fun stop(ctx: Context) {
        val app = ctx.applicationContext
        handler.post { end(app) }
    }

    private fun begin(ctx: Context) {
        running = true
        raiseAlarmVolume(ctx)
        playAlarm(ctx)
        runCatching { vibrator(ctx).vibrate(VibrationEffect.createWaveform(PATTERN, 0)) }
        show(ctx)
        val t = Runnable { end(ctx) }
        timeout = t
        handler.postDelayed(t, DURATION_MS)
    }

    private fun end(ctx: Context) {
        timeout?.let(handler::removeCallbacks)
        timeout = null
        if (!running) return
        running = false
        ringtone?.let { runCatching { it.stop() } }
        ringtone = null
        runCatching { vibrator(ctx).cancel() }
        restoreAlarmVolume(ctx)
        ctx.getSystemService(NotificationManager::class.java).cancel(NOTIF_ID)
    }

    // ---------------------------------------------------------------- sound

    private fun playAlarm(ctx: Context) {
        val uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
        ringtone = runCatching {
            RingtoneManager.getRingtone(ctx, uri)?.apply {
                // USAGE_ALARM: exempt from silent mode and from most Do Not Disturb rules.
                audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                isLooping = true
                play()
            }
        }.onFailure { Log.w(Link.TAG, "could not play the alarm sound", it) }.getOrNull()
    }

    private fun raiseAlarmVolume(ctx: Context) {
        val am = ctx.getSystemService(AudioManager::class.java)
        try {
            // Persisted, not held in a field: if the process dies during the alarm the level
            // has to be recoverable on the next start.
            Store(ctx).savedAlarmVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
            am.setStreamVolume(
                AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0,
            )
        } catch (e: SecurityException) {
            // With Do Not Disturb on, the system refuses volume changes. The alarm still
            // plays, just at whatever level the user had set.
            Store(ctx).savedAlarmVolume = -1
            Log.i(Link.TAG, "could not raise the alarm volume: ${e.message}")
        }
    }

    /** Also called by the service on start, to undo a raise a process death left behind. */
    fun restoreAlarmVolume(ctx: Context) {
        val store = Store(ctx)
        val saved = store.savedAlarmVolume
        if (saved < 0) return
        store.savedAlarmVolume = -1
        runCatching {
            ctx.getSystemService(AudioManager::class.java)
                .setStreamVolume(AudioManager.STREAM_ALARM, saved, 0)
        }
    }

    private fun vibrator(ctx: Context): Vibrator =
        if (Build.VERSION.SDK_INT >= 31) {
            ctx.getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            ctx.getSystemService(Vibrator::class.java)
        }

    // ---------------------------------------------------------------- notification

    private fun show(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL, ctx.getString(R.string.find_channel), NotificationManager.IMPORTANCE_HIGH,
            )
        )
        val stop = PendingIntent.getBroadcast(
            ctx, REQ_STOP, Intent(ctx, FindPhoneStopReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val open = PendingIntent.getActivity(
            ctx, REQ_OPEN,
            Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        nm.notify(
            NOTIF_ID,
            Notification.Builder(ctx, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(ctx.getString(R.string.find_title))
                .setContentText(ctx.getString(R.string.find_text))
                .setCategory(Notification.CATEGORY_ALARM)
                .setContentIntent(open)
                .setDeleteIntent(stop)                       // swiping it away stops the alarm too
                .addAction(
                    Notification.Action.Builder(
                        null as Icon?, ctx.getString(R.string.find_stop), stop,
                    ).build()
                )
                .setAutoCancel(true)
                .build()
        )
    }

    private const val CHANNEL = "find"
    private const val NOTIF_ID = 3
    private const val REQ_STOP = 3
    private const val REQ_OPEN = 4
    private const val DURATION_MS = 30_000L
    private val PATTERN = longArrayOf(0, 700, 500)
}

/** The notification's "Found it" action and the swipe-away land here. exported=false in the manifest. */
class FindPhoneStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = FindPhone.stop(context)
}
