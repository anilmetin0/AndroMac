package dev.andromac.ui

import android.app.Activity
import android.view.View
import android.widget.Switch
import android.widget.TextView
import dev.andromac.R

/**
 * Helpers for binding a settings row.
 *
 * Settings are spread across three screens (main, notifications, clipboard); rather than
 * repeating the same row behaviour in three places we keep it here: the whole row is
 * tappable, and the switch does not steal the click.
 */

fun Activity.bindSwitchRow(rowId: Int, switchId: Int, initial: Boolean, set: (Boolean) -> Unit) {
    val toggle = findViewById<Switch>(switchId).apply { isChecked = initial }
    // The row tap only flips the switch; the checked-change listener is the SOLE writer.
    // Writing here as well made every tap save the preference twice.
    findViewById<View>(rowId).setOnClickListener { toggle.isChecked = !toggle.isChecked }
    toggle.setOnCheckedChangeListener { _, checked -> set(checked) }
}

/** Dims a row and makes it untappable while another toggle is off. */
fun Activity.setRowEnabled(rowId: Int, enabled: Boolean) {
    findViewById<View>(rowId).apply {
        isEnabled = enabled
        alpha = if (enabled) 1f else 0.4f
    }
}

fun Activity.bindNavRow(rowId: Int, onClick: () -> Unit) {
    findViewById<View>(rowId).setOnClickListener { onClick() }
}

/** The same summary on both screens: "12 apps · 3 restricted". */
fun dev.andromac.core.Store.appFilterSummary(activity: Activity): String {
    val total = seenApps.size
    val limited = appModes.count { it.value != dev.andromac.core.Store.MODE_FULL }
    return when {
        total == 0 -> activity.getString(R.string.apps_summary_empty)
        limited == 0 -> activity.resources.getQuantityString(R.plurals.apps_summary, total, total)
        else -> activity.getString(R.string.apps_summary_limited, total, limited)
    }
}

/**
 * "1.0.0 (12 · abc1234)" — the same value at the bottom of the main screen and in the help
 * diagnostics. The version is the first thing asked for in a bug report; the user should not
 * have to go digging in system Settings for it. The commit comes from the build (it reads
 * "local" outside CI) and turns a screenshot into an exact revision.
 */
fun Activity.versionLabel(): String = runCatching {
    val pm = packageManager
    val info = if (android.os.Build.VERSION.SDK_INT >= 33) {
        pm.getPackageInfo(packageName, android.content.pm.PackageManager.PackageInfoFlags.of(0))
    } else {
        @Suppress("DEPRECATION") pm.getPackageInfo(packageName, 0)
    }
    "${info.versionName} (${info.longVersionCode} · ${getString(R.string.build_commit)})"
}.getOrDefault("")

/** The shared shell of the detail screens: header, back button, and system-bar padding. */
fun Activity.setupDetailScreen(layoutId: Int, titleRes: Int) {
    setContentView(layoutId)
    findViewById<View>(R.id.scrollRoot).padForSystemBars()
    findViewById<TextView>(R.id.headerTitle).setText(titleRes)
    findViewById<View>(R.id.headerBack).setOnClickListener { finish() }
}
