package dev.andromac.ui

import android.graphics.Insets
import android.os.Build
import android.view.View
import android.view.WindowInsets

/**
 * With targetSdk 35+ edge-to-edge is MANDATORY: content is drawn underneath the system bars.
 * We add the height of BOTH the top and the bottom bar as padding on the root scrolling
 * surface; with `clipToPadding="false"` the content still scrolls beneath the bars.
 *
 * The top inset is applied here now: the framework ActionBar is disabled (view_header.xml),
 * so nobody was accounting for the status bar on our behalf and the header sat underneath it.
 */
fun View.padForSystemBars() {
    val baseTop = paddingTop
    val baseBottom = paddingBottom
    setOnApplyWindowInsetsListener { view, windowInsets ->
        val bars = systemBarInsets(windowInsets)
        view.setPadding(
            view.paddingLeft, baseTop + bars.top, view.paddingRight, baseBottom + bars.bottom,
        )
        windowInsets
    }
    requestApplyInsets()
}

private fun systemBarInsets(insets: WindowInsets): Insets =
    if (Build.VERSION.SDK_INT >= 30) {
        insets.getInsets(WindowInsets.Type.systemBars())
    } else {
        @Suppress("DEPRECATION")
        Insets.of(0, insets.systemWindowInsetTop, 0, insets.systemWindowInsetBottom)
    }

