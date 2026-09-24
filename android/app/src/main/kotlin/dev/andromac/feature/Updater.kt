package dev.andromac.feature

import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.feature.UpdateCheck.Problem
import dev.andromac.feature.UpdateCheck.Step
import java.io.File
import java.io.IOException
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import javax.net.ssl.HttpsURLConnection

/**
 * Downloads a release APK and hands it to the system installer.
 *
 * AndroMac is not on any store, so "there is a new version" has to be followed by something the
 * user can press. This is that button: fetch the APK the release publishes, check it against the
 * release's own `SHA256SUMS.txt`, then hand it to [PackageInstaller]. On Android 12 and later the
 * session asks for no confirmation, which the system grants to an app updating itself
 * (`UPDATE_PACKAGES_WITHOUT_USER_ACTION`); where it
 * does not, the system's own install dialog comes up as before. The automatic install
 * ([install] with `whenAway`) commits only once none of the app's screens is on display.
 *
 * Every way out of the work ends in [Step.Idle] or [Step.Failed], never in a state nothing
 * leaves: a dropped connection times out, a short or altered download fails its checksum, and a
 * confirmation dismissed without a result is caught by [recheck] when a screen comes back.
 *
 * What it will not do:
 *  - download anything but a `browser_download_url` of this repository's releases ([UpdateCheck]);
 *  - install a file whose checksum is absent from `SHA256SUMS.txt` or does not match it;
 *  - keep the download around: the APK is deleted as soon as the session is committed or fails.
 *
 * Android verifies the signature on top of all this: an APK signed with a different key than the
 * installed app is refused by the system, whatever this code does.
 */
object Updater {

    @Volatile
    var state: Step = Step.Idle
        private set

    /** The session last committed, so [recheck] can tell whether it is still open. */
    @Volatile
    private var sessionId = -1

    private val main = Handler(Looper.getMainLooper())

    /** Screens that follow the install; called on the main thread for every state change. */
    private val listeners = CopyOnWriteArrayList<(Step) -> Unit>()

    fun addListener(l: (Step) -> Unit) { listeners += l }
    fun removeListener(l: (Step) -> Unit) { listeners -= l }

    /** The system's confirmation, held while no screen was open to show it ([Step.Confirm]). */
    private var confirm: Intent? = null

    /** The system needs this before it may show an install dialog for our download. */
    fun canInstall(ctx: Context): Boolean = ctx.packageManager.canRequestPackageInstalls()

    fun installPermissionIntent(ctx: Context): Intent =
        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}"))

    /**
     * Download, verify and start the install. Every step reaches the [addListener] listeners on
     * the main thread, so a screen can follow along; the work happens on a daemon thread of its own.
     *
     * With [whenAway] the verified APK waits in [Step.Ready] until none of the app's activities
     * is started, so an update never closes the screen the user is looking at. Main thread only.
     */
    fun install(ctx: Context, release: UpdateCheck.Release, whenAway: Boolean = false) {
        if (!whenAway) {
            // Asked to install now while a download waits for the user to leave: now it is.
            if (state == Step.Ready) { pendingCommit?.let { pendingCommit = null; it() }; return }
            // The confirmation the system asked for while the app was away: a screen is open now.
            if (state == Step.Confirm) {
                val intent = confirm ?: return publish(Step.Failed(Problem.INSTALL))
                confirm = null
                ctx.getSystemService(NotificationManager::class.java).cancel(NOTIF_CONFIRM)
                publish(Step.Installing)
                if (runCatching { ctx.startActivity(intent) }.isFailure) publish(Step.Failed(Problem.INSTALL))
                return
            }
        }
        if (state != Step.Idle && state !is Step.Failed) return
        val app = ctx.applicationContext
        val apk = release.apk
        val sums = release.checksums
        if (apk == null || sums == null) {
            publish(Step.Failed(Problem.NO_ASSET))
            return
        }
        publish(Step.Downloading(null))
        Thread({
            var file: File? = null
            try {
                val downloaded = download(app, apk).also { file = it }

                publish(Step.Verifying)
                val expected = checksum(sums, apk.name) ?: throw Mismatch()
                if (!expected.equals(sha256(downloaded), ignoreCase = true)) throw Mismatch()

                file = null                          // commitAndDelete deletes it
                if (whenAway) {
                    publish(Step.Ready)
                    main.post {
                        val commitNow = {
                            Thread({ commitAndDelete(app, downloaded) }, "andromac-updater")
                                .apply { isDaemon = true }.start()
                        }
                        if (started <= 0) commitNow() else pendingCommit = commitNow
                    }
                } else {
                    commitAndDelete(app, downloaded)
                }
            } catch (e: Exception) {
                Log.i(Link.TAG, "update failed: $e")
                publish(Step.Failed(if (e is Mismatch) Problem.CHECKSUM else if (e is IOException) Problem.NETWORK else Problem.INSTALL))
            } finally {
                // Nothing verified to keep: a failed download is of no use to anyone.
                file?.delete()
            }
        }, "andromac-updater").apply { isDaemon = true }.start()
    }

    /** The download does not match the release's checksum file, or the file does not list it. */
    private class Mismatch : IOException("checksum mismatch")

    private fun commitAndDelete(ctx: Context, file: File) {
        try {
            publish(Step.Installing)
            commit(ctx, file)
        } catch (e: Exception) {
            Log.i(Link.TAG, "update failed: $e")
            publish(Step.Failed(Problem.INSTALL))
        } finally {
            // The session copied the bytes it needs; ours are of no use to anyone afterwards.
            file.delete()
        }
    }

    /**
     * A screen came back while [Step.Installing]: if the session is gone, the confirmation was
     * dismissed and no result reached [InstallReceiver] (not every build sends one), so the
     * button turns into Retry instead of waiting for ever. An update that went through would
     * have ended this process.
     */
    fun recheck(ctx: Context) {
        val id = sessionId
        if (state != Step.Installing || id < 0) return
        if (ctx.packageManager.packageInstaller.getSessionInfo(id) == null) publish(Step.Failed(Problem.CANCELLED))
    }

    /** Activities of this app that are started; the automatic install waits for zero. Main thread only. */
    private var started = 0
    private var watching = false
    private var pendingCommit: (() -> Unit)? = null

    /**
     * Counts started activities. Called once from [dev.andromac.App.onCreate],
     * before any activity exists, so the count starts at a true zero whichever screen the process
     * comes up in.
     */
    fun watchScreens(app: Application) {
        if (watching) return
        watching = true
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) { started++ }
            override fun onActivityStopped(activity: Activity) {
                started = (started - 1).coerceAtLeast(0)
                // A rotation stops the screen only to start it again at once.
                if (started <= 0 && !activity.isChangingConfigurations) pendingCommit?.let { pendingCommit = null; it() }
            }
            override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    // ---------------------------------------------------------------- steps

    private fun publish(next: Step) {
        state = next
        main.post { listeners.forEach { it(next) } }
    }

    /**
     * No screen is open, so the confirmation cannot be started from here (Android blocks
     * background activity starts). A notification carries it instead, and Install re-enables.
     */
    private fun awaitConfirm(ctx: Context, intent: Intent) {
        confirm = intent
        publish(Step.Confirm)
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, ctx.getString(R.string.settings_updates), NotificationManager.IMPORTANCE_DEFAULT)
        )
        val tap = PendingIntent.getActivity(
            ctx, NOTIF_CONFIRM, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(ctx.getString(R.string.update_card_title))
            .setContentText(ctx.getString(R.string.update_confirm))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build()
        // Without the notification permission this is a no-op; the Install button still works.
        runCatching { nm.notify(NOTIF_CONFIRM, n) }
    }

    private fun download(ctx: Context, asset: UpdateCheck.Asset): File {
        val directory = File(ctx.cacheDir, "update").apply { mkdirs() }
        // One file, always the same name: a failed attempt cannot pile up copies in the cache.
        val file = File(directory, "update.apk")
        val conn = open(asset.url)
        try {
            if (conn.responseCode != 200) throw IOException("HTTP ${conn.responseCode}")
            // The final response's length, after GitHub's redirect; the API's size otherwise.
            val size = conn.contentLengthLong.takeIf { it > 0 } ?: asset.size
            var total = 0L
            var shown: Int? = null
            conn.inputStream.use { input ->
                file.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_APK) throw IOException("download too large")
                        output.write(buf, 0, n)
                        val percent = UpdateCheck.percent(total, size)
                        if (percent != shown) { shown = percent; publish(Step.Downloading(percent)) }
                    }
                }
            }
            // A connection that closed early is a network problem, not a checksum one.
            if (size > 0 && total < size) throw IOException("download ended at $total of $size bytes")
            return file
        } finally {
            conn.disconnect()
        }
    }

    /** The hash for [name] in the release's checksum file ([UpdateCheck.checksum]). */
    private fun checksum(asset: UpdateCheck.Asset, name: String): String? {
        val conn = open(asset.url)
        try {
            if (conn.responseCode != 200) throw IOException("HTTP ${conn.responseCode}")
            val text = conn.inputStream.bufferedReader().use { it.readBounded(MAX_SUMS) }
            return UpdateCheck.checksum(text, name)
        } finally {
            conn.disconnect()
        }
    }

    /**
     * Hand the APK to the system. The install dialog is the system's own; this only writes the
     * bytes into a session and commits it.
     */
    private fun commit(ctx: Context, file: File) {
        val installer = ctx.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        // The session fails unless the APK is this very package. Without it, a release asset with
        // another package name would install as a second app, behind an ordinary Install dialog.
        // The platform then enforces that the signer is ours, as for any update.
        params.setAppPackageName(ctx.packageName)
        // An app updating itself may skip the confirmation on Android 12+. When the system does
        // not allow it, the result is STATUS_PENDING_USER_ACTION and the dialog comes up anyway.
        if (Build.VERSION.SDK_INT >= 31) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        sessionId = id
        try {
            installer.openSession(id).use { session ->
                session.openWrite("andromac", 0, file.length()).use { output ->
                    file.inputStream().use { it.copyTo(output) }
                    session.fsync(output)
                }
                val intent = PendingIntent.getBroadcast(
                    ctx, 8, Intent(ACTION_INSTALLED).setPackage(ctx.packageName),
                    PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                session.commit(intent.intentSender)
            }
        } catch (e: Exception) {
            // A half-written session would sit in the installer until the next reboot.
            runCatching { installer.abandonSession(id) }
            throw e
        }
    }

    private fun open(url: String): HttpsURLConnection {
        // Redirects are followed by the platform, but only ever to another https URL.
        val conn = URL(url).openConnection() as HttpsURLConnection
        conn.connectTimeout = TIMEOUT_MS
        conn.readTimeout = TIMEOUT_MS
        conn.instanceFollowRedirects = true
        conn.setRequestProperty("Accept", "application/octet-stream")
        conn.setRequestProperty("User-Agent", "AndroMac")
        return conn
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /** Bounded read: a checksum file is a few hundred bytes, and this one is not ours. */
    private fun java.io.BufferedReader.readBounded(limit: Int): String {
        val buf = CharArray(limit)
        var total = 0
        while (total < limit) {
            val n = read(buf, total, limit - total)
            if (n < 0) break
            total += n
        }
        return String(buf, 0, total)
    }

    /** The result of a commit: the system reports it here, including "ask the user first". */
    class InstallReceiver : android.content.BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    // The system's own confirmation dialog. Nothing is installed before it.
                    val confirm = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    }
                        ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    if (confirm == null) { publish(Step.Failed(Problem.INSTALL)); return }
                    // A screen is open: the dialog comes up over it. Otherwise it waits for one.
                    if (started > 0 && runCatching { ctx.startActivity(confirm) }.isSuccess) return
                    awaitConfirm(ctx, confirm)
                }
                PackageInstaller.STATUS_SUCCESS -> publish(Step.Idle)
                else -> {
                    val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
                    Log.i(Link.TAG, "install did not complete: $status ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}")
                    Updater.confirm = null
                    ctx.getSystemService(NotificationManager::class.java).cancel(NOTIF_CONFIRM)
                    publish(Step.Failed(when (status) {
                        PackageInstaller.STATUS_FAILURE_ABORTED -> Problem.CANCELLED
                        // Signed with another key, or another package: the system will not replace the app with it.
                        PackageInstaller.STATUS_FAILURE_CONFLICT -> Problem.CONFLICT
                        PackageInstaller.STATUS_FAILURE_STORAGE -> Problem.STORAGE
                        else -> Problem.INSTALL
                    }))
                }
            }
        }
    }

    const val ACTION_INSTALLED = "dev.andromac.INSTALLED"
    private const val CHANNEL = "andromac.updates"
    private const val NOTIF_CONFIRM = 9
    private const val TIMEOUT_MS = 15_000
    private const val MAX_SUMS = 64 * 1024
    /** 200 MB: two orders of magnitude above the real APK, and still a bound. */
    private const val MAX_APK = 200L * 1024 * 1024
}
