package dev.andromac.feature

import android.content.pm.PackageManager
import java.util.concurrent.ConcurrentHashMap

/**
 * The label the user sees, instead of the package name. Falls back to the package name when
 * it cannot be read — the label must always show something, never "null".
 *
 * The notification mirror and the media bridge send the same label; it lives in one place so
 * the same app never shows up on the Mac under two different names.
 */
fun PackageManager.appLabel(pkg: String): String = labels.getOrPut(pkg) {
    runCatching { getApplicationLabel(getApplicationInfo(pkg, 0)).toString() }.getOrDefault(pkg)
}

/**
 * Every notification used to pay a binder call to PackageManager on the listener's main
 * thread. Labels change only when an app is installed or updated, so they are memoized for
 * the life of the process; the ceiling is that a renamed app keeps its old label until the
 * next restart. Bounded by the number of installed apps.
 */
private val labels = ConcurrentHashMap<String, String>()
