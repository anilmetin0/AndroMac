package io.github.anilmetin0.andromac.feature

import io.github.anilmetin0.andromac.core.Link
import io.github.anilmetin0.andromac.core.Protocol
import io.github.anilmetin0.andromac.core.Store

/**
 * Mirrors the app modes to the Mac. The Mac uses them to show which apps are muted and to
 * mute or unmute an app straight from a notification.
 *
 * The filter itself still runs ON THE PHONE (PROTOCOL §6.6); this list exists only for
 * display and for remote changes.
 */
object AppModeSync {

    fun push(store: Store) {
        if (!Link.isConnected) return
        val labels = store.seenApps
        val modes = store.appModes
        // Every app that has ever posted a notification is listed; with no explicit mode the default is FULL.
        val apps = labels.map { (pkg, label) ->
            Protocol.AppMode(pkg, label, modes[pkg] ?: Store.MODE_FULL)
        }.sortedBy { it.label.lowercase() }
        Link.send(Protocol.appModes(apps))
    }
}
