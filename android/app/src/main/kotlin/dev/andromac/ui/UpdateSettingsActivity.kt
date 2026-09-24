package dev.andromac.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Typeface
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.StyleSpan
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import dev.andromac.R
import dev.andromac.core.Store
import dev.andromac.core.Version
import dev.andromac.feature.UpdateCheck
import dev.andromac.feature.Updater

/**
 * The update check: on/off, automatic install, beta, and one button that does what the moment
 * needs ([UpdateCheck.action]): check, download and install with its progress, install what is
 * ready, or retry what failed. The release notes show while a newer build is known.
 */
class UpdateSettingsActivity : Activity() {

    private lateinit var store: Store
    private var checking = false
    /** The "install unknown apps" screen is open for us; back from it, the install goes on. */
    private var awaitingPermission = false
    private var permissionRefused = false
    /** Download and install once the running check has found the release with its assets. */
    private var installAfterCheck = false
    private val installChanged: (UpdateCheck.Step) -> Unit = { if (!isFinishing) refresh() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_updates, R.string.update_title)
        store = Store(this)
        // The permission screen can cost the process its life; the intent to install survives.
        awaitingPermission = savedInstanceState?.getBoolean(KEY_AWAITING) == true

        bindSwitchRow(R.id.rowCheck, R.id.swCheck, store.updateCheck) {
            store.updateCheck = it
            if (it) check() else refresh()
        }
        bindSwitchRow(R.id.rowAuto, R.id.swAuto, autoInstallUpdates) { autoInstallUpdates = it }
        bindSwitchRow(R.id.rowBeta, R.id.swBeta, betaUpdates) {
            betaUpdates = it
            forgetFoundUpdate(store)
            // Turning Beta on asks the beta channel at once: the switch is the consent. Off, only
            // with the check on; stable never offers a lower build than the one running, so
            // switching back is never a downgrade. A check still running for the old channel
            // re-runs by itself ([runUpdateCheck]).
            if (it || store.updateCheck) check() else refresh()
        }
        findViewById<Button>(R.id.download).setOnClickListener { primary() }

        if (isDebuggable() && intent.getBooleanExtra(EXTRA_FAKE_UPDATE, false)) fakeUpdate()
        when {
            // Install now in the dialog of the main screen: this screen shows the progress.
            savedInstanceState == null && intent.getBooleanExtra(EXTRA_INSTALL, false) -> installWhenFound()
            // A release restored from disk has no asset list; one request lets the button install it.
            !checkedThisProcess && store.updateFound != null -> check()
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

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_AWAITING, awaitingPermission)
    }

    /** Back from the permission screen or the system installer (a cancel may reach no receiver). */
    override fun onResume() {
        super.onResume()
        Updater.recheck(this)
        if (awaitingPermission) {
            awaitingPermission = false
            if (Updater.canInstall(this)) installWhenFound() else permissionRefused = true
        }
        refresh()
    }

    /** "Check now" works even while the automatic check is off: an explicit tap is consent. */
    private fun check() {
        if (checking) return
        checking = true
        refresh()
        runUpdateCheck(store) {
            checking = false
            if (installAfterCheck) {
                installAfterCheck = false
                newerRelease(store)?.takeIf { it.apk != null && it.checksums != null }?.let(::install)
            }
            refresh()
        }
    }

    /** The one button. */
    private fun primary() {
        val newer = newerRelease(store)
        when (UpdateCheck.action(checking, newer, Updater.state)) {
            UpdateCheck.Action.CHECK -> check()
            UpdateCheck.Action.WAIT -> Unit
            UpdateCheck.Action.OPEN_PAGE -> newer?.let { openReleasePage(it.url) }
            UpdateCheck.Action.DOWNLOAD, UpdateCheck.Action.INSTALL, UpdateCheck.Action.RETRY -> newer?.let(::install)
        }
        refresh()
    }

    private fun installWhenFound() {
        val newer = newerRelease(store)
        if (!checking && newer?.apk != null && newer.checksums != null) install(newer)
        else { installAfterCheck = true; check() }
    }

    /**
     * Download, verify and install now, the app in front: the system shows its confirmation if
     * it wants one. Without the "install unknown apps" permission there is nothing to hand the
     * APK to, so that screen opens first and [onResume] carries on.
     */
    private fun install(release: UpdateCheck.Release) {
        permissionRefused = false
        if (!Updater.canInstall(this)) {
            awaitingPermission = true
            startActivity(Updater.installPermissionIntent(this))
            return
        }
        Updater.install(this, release)
    }

    private fun refresh() {
        val step = Updater.state
        val newer = newerRelease(store)
        val action = UpdateCheck.action(checking, newer, step)

        findViewById<TextView>(R.id.checkSummary).text = when {
            checking -> getString(R.string.update_status_checking)
            permissionRefused && step !is UpdateCheck.Step.Downloading -> getString(R.string.update_permission)
            else -> updateStatus(store)
        }
        findViewById<ProgressBar>(R.id.progress).apply {
            val percent = (step as? UpdateCheck.Step.Downloading)?.percent
            visibility = if (step is UpdateCheck.Step.Downloading) View.VISIBLE else View.GONE
            isIndeterminate = percent == null
            if (percent != null) progress = percent
        }

        val notes = newer?.let { releaseNotes(it) }
        findViewById<TextView>(R.id.notes).apply {
            visibility = if (notes.isNullOrEmpty()) View.GONE else View.VISIBLE
            text = notes
        }
        findViewById<Button>(R.id.download).apply {
            isEnabled = action != UpdateCheck.Action.WAIT
            text = when (action) {
                UpdateCheck.Action.CHECK ->
                    getString(if (lastUpdateError != null) R.string.update_retry else R.string.update_check)
                UpdateCheck.Action.WAIT -> if (checking) getString(R.string.update_status_checking) else installLine() ?: ""
                UpdateCheck.Action.OPEN_PAGE -> getString(R.string.update_open_page)
                UpdateCheck.Action.DOWNLOAD -> getString(R.string.update_download_install)
                UpdateCheck.Action.INSTALL -> getString(R.string.update_install_now)
                UpdateCheck.Action.RETRY -> getString(R.string.update_retry)
            }
        }
    }

    /**
     * Debug builds only, for checking the screen's states without a newer signed APK: a release
     * 99.0.0 whose APK is the real v1.1.0 download under a name its checksum file does not list.
     * It downloads with progress, verifies, and stops at the checksum error with Retry; nothing
     * is ever handed to the installer.
     * `adb shell am start -n dev.andromac.debug/dev.andromac.ui.UpdateSettingsActivity --ez fake_update true`
     * (as root: the screen is not exported).
     */
    private fun fakeUpdate() {
        val base = "https://github.com/${UpdateCheck.REPO}/releases/download/v1.1.0/"
        lastFound = UpdateCheck.Release(
            Version(99, 0, 0), "0000000", "https://github.com/${UpdateCheck.REPO}/releases/latest",
            listOf(
                UpdateCheck.Asset("AndroMac-99.0.0-android.apk", base + "AndroMac-1.1.0-android.apk", 288_062),
                UpdateCheck.Asset("SHA256SUMS.txt", base + "SHA256SUMS.txt", 190),
            ),
            build = 999_999, body = "## Debug\n\n- A made-up release for checking this screen.",
        )
        lastFoundBeta = betaUpdates
        checkedThisProcess = true
    }

    private fun isDebuggable() = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

    companion object {
        /** Start the download and install as soon as the screen opens. */
        const val EXTRA_INSTALL = "install"
        private const val EXTRA_FAKE_UPDATE = "fake_update"
        private const val KEY_AWAITING = "awaiting_permission"
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

/** One line: what the install is doing or why it stopped, else what the last check found. */
fun Activity.updateStatus(store: Store): String {
    installLine()?.let { return it }
    if (lastUpdateError != null) return getString(R.string.update_status_error)
    val last = store.updateLastCheck
    if (last == 0L) return getString(R.string.update_status_never)
    val ago = ago(last)
    val newer = newerRelease(store)
    return if (newer == null) getString(R.string.update_status_uptodate, ago)
    else getString(R.string.update_status_available, newer.label, ago)
}

/** What the installer is doing, or why it stopped, in one line. Null while it has nothing to say. */
fun Activity.installLine(): String? = when (val s = Updater.state) {
    UpdateCheck.Step.Idle -> null
    is UpdateCheck.Step.Downloading ->
        s.percent?.let { getString(R.string.update_downloading_percent, it) } ?: getString(R.string.update_downloading)
    UpdateCheck.Step.Verifying -> getString(R.string.update_verifying)
    UpdateCheck.Step.Ready -> getString(R.string.update_ready)
    UpdateCheck.Step.Installing -> getString(R.string.update_installing)
    UpdateCheck.Step.Confirm -> getString(R.string.update_confirm)
    is UpdateCheck.Step.Failed -> getString(when (s.problem) {
        UpdateCheck.Problem.NETWORK -> R.string.update_failed_network
        UpdateCheck.Problem.CHECKSUM -> R.string.update_failed_checksum
        UpdateCheck.Problem.NO_ASSET -> R.string.update_failed_no_asset
        UpdateCheck.Problem.CANCELLED -> R.string.update_failed_cancelled
        UpdateCheck.Problem.CONFLICT -> R.string.update_failed_conflict
        UpdateCheck.Problem.STORAGE -> R.string.update_failed_storage
        UpdateCheck.Problem.INSTALL -> R.string.update_failed_install
    })
}

/** The main screen's update card: the install's progress while there is any, else the offer. */
fun Activity.updateCardBody(release: UpdateCheck.Release): String =
    installLine() ?: getString(R.string.update_card_body, release.label)

/** The Updates screen, starting the download and install at once. */
fun Activity.startUpdateInstall() {
    startActivity(Intent(this, UpdateSettingsActivity::class.java).putExtra(UpdateSettingsActivity.EXTRA_INSTALL, true))
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
        release.checksums != null && Updater.canInstall(this) && Updater.state !is UpdateCheck.Step.Failed
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
            if (release.apk == null) openReleasePage(release.url) else startUpdateInstall()
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
