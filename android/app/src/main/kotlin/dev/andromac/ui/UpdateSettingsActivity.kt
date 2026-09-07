package dev.andromac.ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.text.format.DateUtils
import android.widget.Button
import android.widget.TextView
import dev.andromac.R
import dev.andromac.core.Store
import dev.andromac.core.Version
import dev.andromac.feature.UpdateCheck

/** The update check: on/off, check now, and the download button when one is due. */
class UpdateSettingsActivity : Activity() {

    private lateinit var store: Store
    private var checking = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_updates, R.string.update_title)
        store = Store(this)

        bindSwitchRow(R.id.rowCheck, R.id.swCheck, store.updateCheck) {
            store.updateCheck = it
            if (it) check() else refresh()
        }
        bindNavRow(R.id.rowCheckNow) { check() }
        findViewById<Button>(R.id.download).setOnClickListener {
            store.updateFound?.url?.let(::openReleasePage)
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
            refresh()
        }
    }

    private fun refresh() {
        setRowEnabled(R.id.rowCheckNow, !checking)

        findViewById<TextView>(R.id.checkSummary).text =
            if (checking) getString(R.string.update_status_checking) else updateStatus(store)

        val newer = store.newerRelease(currentVersion(), currentCommit())
        findViewById<Button>(R.id.download).apply {
            visibility = if (newer == null) android.view.View.GONE else android.view.View.VISIBLE
            if (newer != null) text = getString(R.string.update_download, newer.label)
        }
    }
}

// ---------------------------------------------------------------- shared with MainActivity

/** The version this build reports, or 0.0.0 if the package info is somehow unreadable. */
fun Activity.currentVersion(): Version = Version.find(versionLabel()) ?: Version(0, 0, 0)

/** The commit this build was made from; "local" outside CI (build.gradle.kts). */
fun Activity.currentCommit(): String = getString(R.string.build_commit)

/** The release the last check found, but only while it is still newer than what is running. */
fun Store.newerRelease(current: Version, currentCommit: String): UpdateCheck.Release? =
    updateFound?.takeIf { UpdateCheck.isNewer(it, current, currentCommit) }

/**
 * Runs the check now and stores the outcome; [done] runs on the UI thread. The error is not
 * persisted: a flaky network at one launch should not show a warning at the next.
 */
private var lastUpdateError: String? = null

fun Activity.runUpdateCheck(store: Store, done: () -> Unit = {}) {
    UpdateCheck.checkAsync(currentVersion(), currentCommit()) { result ->
        result.onSuccess { release ->
            store.updateFound = release
            store.updateLastCheck = System.currentTimeMillis()
            lastUpdateError = null
        }.onFailure { e ->
            lastUpdateError = e.javaClass.simpleName
        }
        runOnUiThread(done)
    }
}

/** The automatic check: on, and not run within the last day. Called when the main screen opens. */
fun Activity.runUpdateCheckIfDue(store: Store, done: () -> Unit) {
    if (!store.updateCheck) return
    if (System.currentTimeMillis() - store.updateLastCheck < UpdateCheck.INTERVAL_MS) return
    runUpdateCheck(store, done)
}

fun Activity.updateStatus(store: Store): String {
    lastUpdateError?.let { return getString(R.string.update_status_error, it) }
    val last = store.updateLastCheck
    if (last == 0L) return getString(R.string.update_status_never)
    val ago = DateUtils.getRelativeTimeSpanString(last, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
    val newer = store.newerRelease(currentVersion(), currentCommit())
    return if (newer == null) getString(R.string.update_status_uptodate, ago)
    else getString(R.string.update_status_available, newer.label, ago)
}

/** The release page, never anything else: [UpdateCheck.parse] already pinned the host. */
fun Activity.openReleasePage(url: String) {
    if (!url.startsWith("https://github.com/")) return
    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
}
