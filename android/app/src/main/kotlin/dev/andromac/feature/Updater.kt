package dev.andromac.feature

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
import dev.andromac.core.Link
import java.io.File
import java.io.IOException
import java.net.URL
import java.security.MessageDigest
import javax.net.ssl.HttpsURLConnection

/**
 * Downloads a release APK and hands it to the system installer.
 *
 * AndroMac is not on any store, so "there is a new version" has to be followed by something the
 * user can press. This is that button: fetch the APK the release publishes, check it against the
 * release's own `SHA256SUMS.txt`, then open the normal Android install dialog through
 * [PackageInstaller]. The user still confirms the install; nothing happens silently.
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

    sealed interface State {
        data object Idle : State
        data object Downloading : State
        data object Verifying : State
        /** Waiting for the user in the system installer dialog. */
        data object Installing : State
        data class Failed(val reason: String) : State
    }

    @Volatile
    var state: State = State.Idle
        private set

    private val main = Handler(Looper.getMainLooper())

    /** The system needs this before it may show an install dialog for our download. */
    fun canInstall(ctx: Context): Boolean = ctx.packageManager.canRequestPackageInstalls()

    fun installPermissionIntent(ctx: Context): Intent =
        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}"))

    /**
     * Download, verify and start the install. [onState] is called on the main thread for every
     * step, so a screen can follow along; the work happens on a daemon thread of its own.
     */
    fun install(ctx: Context, release: UpdateCheck.Release, onState: (State) -> Unit) {
        if (state != State.Idle && state !is State.Failed) return
        val app = ctx.applicationContext
        val apk = release.apk
        val sums = release.checksums
        if (apk == null || sums == null) {
            publish(State.Failed("no_asset"), onState)
            return
        }
        Thread({
            var file: File? = null
            try {
                publish(State.Downloading, onState)
                file = download(app, apk)

                publish(State.Verifying, onState)
                val expected = checksum(sums, apk.name)
                val actual = sha256(file)
                if (expected == null || !expected.equals(actual, ignoreCase = true)) {
                    throw IOException("checksum mismatch")
                }

                publish(State.Installing, onState)
                commit(app, file)
            } catch (e: Exception) {
                Log.i(Link.TAG, "update failed: ${e.message}")
                publish(State.Failed(e.javaClass.simpleName), onState)
            } finally {
                // The session copied the bytes it needs; ours are of no use to anyone afterwards.
                file?.delete()
            }
        }, "andromac-updater").apply { isDaemon = true }.start()
    }

    fun clearError() {
        if (state is State.Failed) state = State.Idle
    }

    // ---------------------------------------------------------------- steps

    private fun publish(next: State, onState: (State) -> Unit) {
        state = next
        main.post { onState(next) }
    }

    private fun download(ctx: Context, asset: UpdateCheck.Asset): File {
        val directory = File(ctx.cacheDir, "update").apply { mkdirs() }
        // One file, always the same name: a failed attempt cannot pile up copies in the cache.
        val file = File(directory, "update.apk")
        val conn = open(asset.url)
        try {
            if (conn.responseCode != 200) throw IOException("HTTP ${conn.responseCode}")
            var total = 0L
            conn.inputStream.use { input ->
                file.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_APK) throw IOException("download too large")
                        output.write(buf, 0, n)
                    }
                }
            }
            return file
        } finally {
            conn.disconnect()
        }
    }

    /** The `sha256  filename` line for [name] in the release's checksum file. */
    private fun checksum(asset: UpdateCheck.Asset, name: String): String? {
        val conn = open(asset.url)
        try {
            if (conn.responseCode != 200) throw IOException("HTTP ${conn.responseCode}")
            val text = conn.inputStream.bufferedReader().use { it.readBounded(MAX_SUMS) }
            for (line in text.lineSequence()) {
                val parts = line.trim().split(Regex("\\s+"))
                if (parts.size >= 2 && parts.last().endsWith(name)) return parts[0]
            }
            return null
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
        val id = installer.createSession(params)
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
        val n = read(buf, 0, limit)
        return if (n <= 0) "" else String(buf, 0, n)
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
                    runCatching {
                        confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)?.let(ctx::startActivity)
                    }
                }
                PackageInstaller.STATUS_SUCCESS -> state = State.Idle
                else -> {
                    val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                    Log.i(Link.TAG, "install did not complete: $message")
                    state = State.Failed(message ?: "install_failed")
                }
            }
        }
    }

    const val ACTION_INSTALLED = "dev.andromac.INSTALLED"
    private const val TIMEOUT_MS = 15_000
    private const val MAX_SUMS = 64 * 1024
    /** 200 MB: two orders of magnitude above the real APK, and still a bound. */
    private const val MAX_APK = 200L * 1024 * 1024
}
