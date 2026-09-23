package io.github.anilmetin0.andromac.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.format.DateUtils
import android.text.style.StyleSpan
import android.view.View
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import io.github.anilmetin0.andromac.R
import io.github.anilmetin0.andromac.core.Store
import io.github.anilmetin0.andromac.core.Version
import io.github.anilmetin0.andromac.feature.UpdateCheck
import io.github.anilmetin0.andromac.feature.Updater

/** The update check: on/off, automatic install, beta, check now, and the notes and install button when one is due. */
class UpdateSettingsActivity : Activity() {

    private lateinit var store: Store
    private var checking = false
    private val installChanged: (Updater.State) -> Unit = { if (!isFinishing) refresh() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_updates, R.string.update_title)
        store = Store(this)

        bindSwitchRow(R.id.rowCheck, R.id.swCheck, store.updateCheck) {
            store.updateCheck = it
            if (it) check() else refresh()
        }
        bindSwitchRow(R.id.rowAuto, R.id.swAuto, autoInstallUpdates) { autoInstallUpdates = it }
        bindSwitchRow(R.id.rowBeta, R.id.swBeta, betaUpdates) {
            betaUpdates = it
            forgetFoundUpdate(store)
            // Another channel, another answer. Only with the check on: a switch is not a tap on Check now.
            // A check still running for the old channel re-runs by itself ([runUpdateCheck]).
            if (store.updateCheck) check() else refresh()
        }
        bindNavRow(R.id.rowCheckNow) { check() }
        findViewById<Button>(R.id.download).setOnClickListener {
            startUpdateInstall(store)
            refresh()
        }
        refresh()
    }

    override fun onStart() {
        super.onStart()
        Updater.addListener(installChanged)
    }

    override fun onStop() {
        Updater.removeListener(installChanged)
        super.onStop()
    }

    /** "Check now" works even while the automatic check is off: an explicit tap is consent. */
    private fun check() {
        if (checking) return
        checking = true
        refresh()
        runUpdateCheck(store) {
            checking = false
            refresh()
        }
    }

    /** Back from the system installer, which reports a cancel only to [Updater.InstallReceiver]. */
    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        setRowEnabled(R.id.rowCheckNow, !checking)

        findViewById<TextView>(R.id.checkSummary).text = when {
            checking -> getString(R.string.update_status_checking)
            else -> installStatus() ?: updateStatus(store)
        }

        val newer = newerRelease(store)
        val notes = newer?.let { releaseNotes(it) }
        findViewById<TextView>(R.id.notes).apply {
            visibility = if (notes.isNullOrEmpty()) View.GONE else View.VISIBLE
            text = notes
        }
        findViewById<Button>(R.id.download).apply {
            visibility = if (newer == null) View.GONE else View.VISIBLE
            isEnabled = Updater.state == Updater.State.Idle || Updater.state == Updater.State.Ready ||
                Updater.state == Updater.State.Confirm || Updater.state is Updater.State.Failed
            if (newer != null) {
                text = getString(
                    if (newer.apk == null) R.string.update_download else R.string.update_install,
                    newer.label,
                )
            }
        }
    }

    /** What the installer is doing, or why it stopped. Null while it has nothing to say. */
    private fun installStatus(): String? = when (val s = Updater.state) {
        Updater.State.Idle -> null
        Updater.State.Downloading -> getString(R.string.update_downloading)
        Updater.State.Verifying -> getString(R.string.update_verifying)
        Updater.State.Ready -> getString(R.string.update_ready)
        Updater.State.Installing -> getString(R.string.update_installing)
        Updater.State.Confirm -> getString(R.string.update_confirm)
        is Updater.State.Failed -> getString(R.string.update_install_failed, s.reason)
    }
}

// ---------------------------------------------------------------- shared with MainActivity

/** The version this build reports, or 0.0.0 if the package info is somehow unreadable. */
fun Activity.currentVersion(): Version = Version.find(versionLabel()) ?: Version(0, 0, 0)

/** The commit this build was made from; "local" outside CI (build.gradle.kts). */
fun Activity.currentCommit(): String = getString(R.string.build_commit)

/** The CI run that built this copy, which is also the `versionCode`; 1 for local builds. */
fun Activity.currentBuild(): Int =
    runCatching { packageManager.getPackageInfo(packageName, 0).longVersionCode.toInt() }.getOrDefault(0)

// Kept next to Store's update keys, in the same preferences file.
private fun Context.updatePrefs() = getSharedPreferences("andromac", Context.MODE_PRIVATE)

/** Default ON: at app open a newer build is downloaded, verified, and installed once the app is left. */
var Context.autoInstallUpdates: Boolean
    get() = updatePrefs().getBoolean("update_auto", true)
    set(v) = updatePrefs().edit().putBoolean("update_auto", v).apply()

/** Default OFF: follow every build pushed to main (the prereleases), not only stable ones. */
var Context.betaUpdates: Boolean
    get() = updatePrefs().getBoolean("update_beta", false)
    set(v) = updatePrefs().edit().putBoolean("update_beta", v).apply()

/**
 * What the last check in this process found, with its assets and notes, and on which channel
 * (true for beta); [Store] keeps only the version, commit, build and page. Null until a check ran.
 */
private var lastFound: UpdateCheck.Release? = null
private var lastFoundBeta = false
private var checkedThisProcess = false
/** Checks running in this process. Main thread only. */
private var checksInFlight = 0

/**
 * The release to offer, while it is still newer than what is running and belongs to the channel
 * the Beta switch is on now.
 */
fun Activity.newerRelease(store: Store): UpdateCheck.Release? {
    val beta = betaUpdates
    if (checkedThisProcess) return lastFound?.takeIf { lastFoundBeta == beta }
    val stored = store.updateFound?.takeIf { store.updateFoundBeta == beta } ?: return null
    return stored.takeIf { UpdateCheck.isNewer(it, currentVersion(), currentBuild(), currentCommit(), beta) }
}

/** The Beta switch moved: what either channel found before is no answer for the other. */
private fun forgetFoundUpdate(store: Store) {
    lastFound = null
    store.updateFound = null
}

/**
 * Runs the check now and stores the outcome; [done] runs on the UI thread. The error is not
 * persisted: a flaky network at one launch should not show a warning at the next.
 */
private var lastUpdateError: String? = null

fun Activity.runUpdateCheck(store: Store, done: () -> Unit = {}) {
    val beta = betaUpdates
    checksInFlight++
    UpdateCheck.checkAsync(currentVersion(), currentBuild(), currentCommit(), beta) { result ->
        runOnUiThread {
            checksInFlight--
            // The Beta switch moved while this ran: the answer is for the other channel. Ask again.
            if (beta != betaUpdates) { runUpdateCheck(store, done); return@runOnUiThread }
            result.onSuccess { release ->
                lastFound = release
                lastFoundBeta = beta
                checkedThisProcess = true
                store.updateFound = release
                store.updateFoundBeta = beta
                store.updateLastCheck = System.currentTimeMillis()
                lastUpdateError = null
            }.onFailure { e ->
                lastUpdateError = e.javaClass.simpleName
            }
            done()
        }
    }
}

/**
 * The automatic check: on, and not run within the last day. Called when the main screen opens.
 * True when a check is running afterwards: then its [done] is where the offer belongs, not now.
 */
fun Activity.runUpdateCheckIfDue(store: Store, done: () -> Unit): Boolean {
    announceIfUpdated()
    if (!store.updateCheck) return false
    if (checksInFlight > 0) return true
    val due = System.currentTimeMillis() - store.updateLastCheck >= UpdateCheck.INTERVAL_MS
    // A release restored from disk carries no asset list or notes. A pending offer is worth one
    // request even inside the daily window.
    val incomplete = store.updateFound != null && !checkedThisProcess
    if (!due && !incomplete) return false
    runUpdateCheck(store, done)
    return true
}

fun Activity.updateStatus(store: Store): String {
    lastUpdateError?.let { return getString(R.string.update_status_error, it) }
    val last = store.updateLastCheck
    if (last == 0L) return getString(R.string.update_status_never)
    val ago = DateUtils.getRelativeTimeSpanString(last, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
    val newer = newerRelease(store)
    return if (newer == null) getString(R.string.update_status_uptodate, ago)
    else getString(R.string.update_status_available, newer.label, ago)
}

/**
 * Install the release the last check found: download it, check it against the release's own
 * checksum file and hand it to the system installer ([Updater]). Without the "install unknown
 * apps" permission there is no dialog to hand it to, so that settings screen is opened instead.
 */
fun Activity.startUpdateInstall(store: Store) {
    val release = newerRelease(store) ?: return
    val apk = release.apk
    if (apk == null) { openReleasePage(release.url); return }
    if (!Updater.canInstall(this)) {
        startActivity(Updater.installPermissionIntent(this))
        return
    }
    Updater.install(this, release)
}

/** The first open of a different build than last time says so, once. */
private fun Activity.announceIfUpdated() {
    val running = versionLabel()
    val last = updatePrefs().getString("update_last_run", "") ?: ""
    if (last == running) return
    updatePrefs().edit().putString("update_last_run", running).apply()
    if (last.isNotEmpty()) Toast.makeText(this, getString(R.string.update_done, running), Toast.LENGTH_LONG).show()
}

/**
 * At app open, for the release the last check found: with automatic install on (Android 12+,
 * install permission granted, not on a metered network, no failed attempt in this process) it
 * downloads now and installs once the app is left; otherwise the dialog with the release notes,
 * Install now, Later and Skip this version, handed to [onDialog] so the caller can dismiss it.
 * False when there is nothing to offer yet (checking is off, or a check is still running), so
 * the caller can try again later.
 */
fun Activity.offerOrInstallUpdate(store: Store, onDialog: (AlertDialog) -> Unit = {}): Boolean {
    if (!store.updateCheck || checksInFlight > 0) return false
    val release = newerRelease(store) ?: return false
    if (release.label == store.updateSkipped) return false
    // A metered network is the user's data plan: the download waits for a tap on Install now.
    val metered = getSystemService(ConnectivityManager::class.java).isActiveNetworkMetered
    if (autoInstallUpdates && !metered && Build.VERSION.SDK_INT >= 31 && release.apk != null &&
        release.checksums != null && Updater.canInstall(this) && Updater.state !is Updater.State.Failed
    ) {
        Updater.install(this, release, whenAway = true)
        return true
    }
    val notes = releaseNotes(release)
    AlertDialog.Builder(this)
        .setTitle(getString(R.string.update_available_title, release.label))
        .setMessage(
            when {
                release.apk == null -> getString(R.string.update_available_page)
                notes.isNotEmpty() -> notes
                else -> getString(R.string.update_available_body)
            }
        )
        .setPositiveButton(if (release.apk == null) R.string.update_open_page else R.string.update_install_now) { _, _ ->
            if (release.apk == null) openReleasePage(release.url) else startUpdateInstall(store)
        }
        .setNegativeButton(R.string.update_later, null)
        .setNeutralButton(R.string.update_skip) { _, _ -> store.updateSkipped = release.label }
        .show()
        .also(onDialog)
    return true
}

/**
 * The release notes as text: headings bold, bullets as dots, inline Markdown reduced to its text.
 * The Turkish block when the app runs in Turkish, the English notes otherwise.
 */
fun Activity.releaseNotes(release: UpdateCheck.Release): CharSequence {
    val turkish = resources.configuration.locales[0].language == "tr"
    val out = SpannableStringBuilder()
    for (line in UpdateCheck.notes(release.body, turkish).lines()) {
        val t = line.trim()
        if (out.isNotEmpty()) out.append('\n')
        when {
            t.startsWith("#") -> {
                val start = out.length
                out.append(UpdateCheck.inline(t.trimStart('#').trim()))
                out.setSpan(StyleSpan(Typeface.BOLD), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            t.startsWith("- ") || t.startsWith("* ") -> out.append("•  ").append(UpdateCheck.inline(t.substring(2)))
            else -> out.append(UpdateCheck.inline(t))
        }
    }
    return out
}

/** The release page, never anything else: [UpdateCheck.parse] already pinned the host. */
fun Activity.openReleasePage(url: String) {
    if (!url.startsWith("https://github.com/")) return
    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
}
