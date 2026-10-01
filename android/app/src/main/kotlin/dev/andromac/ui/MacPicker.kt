package dev.andromac.ui

import android.app.Activity
import android.app.AlertDialog
import android.widget.SimpleAdapter
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Store
import dev.andromac.net.Discovery
import dev.andromac.net.LinkService

/**
 * Pair: browse, then list every Mac that answered with its address, and dial only the one the
 * user picks, even when it is the only one. A Mac saved on this phone under the same name is
 * switched to instead of paired again. [shown] gets each dialog, so the screen can dismiss it
 * in onStop.
 *
 * The browse runs here rather than in the link loop: picking needs a list, not a connection.
 * ponytail: on API 29-33 it can collide with a browse the service runs at the same moment
 * (paired and searching), and a resolve there may fail; Search again covers it.
 */
fun Activity.pickMac(store: Store, shown: (AlertDialog) -> Unit = {}) {
    val searching = AlertDialog.Builder(this)
        .setMessage(R.string.pair_searching)
        .setNegativeButton(android.R.string.cancel, null)
        .show()
    shown(searching)
    Thread {
        val peers = Discovery(this).browse(settleMs = SETTLE_MS) { it.isNotEmpty() }
        Link.macSeenOnNetwork = peers.isNotEmpty()
        runOnUiThread {
            if (!searching.isShowing || isFinishing || isDestroyed) return@runOnUiThread
            searching.dismiss()
            val b = AlertDialog.Builder(this)
                .setTitle(R.string.pair_choose_title)
                .setNeutralButton(R.string.pair_search_again) { _, _ -> pickMac(store, shown) }
                .setNegativeButton(android.R.string.cancel, null)
            if (peers.isEmpty()) b.setMessage(R.string.onboarding_step1_missing)
            else {
                val rows = peers.map { mapOf("name" to it.name, "ip" to it.host.hostAddress) }
                val adapter = SimpleAdapter(
                    this, rows, android.R.layout.simple_list_item_2,
                    arrayOf("name", "ip"), intArrayOf(android.R.id.text1, android.R.id.text2),
                )
                b.setAdapter(adapter) { _, i ->
                    val peer = peers[i]
                    val saved = store.savedMacs.firstOrNull { it.name == peer.name }
                    if (saved != null) {
                        store.activate(saved)
                        store.lastEndpoint = "${peer.host.hostAddress}:${peer.port}"
                        LinkService.start(this, LinkService.ACTION_SWITCH)
                    } else {
                        store.unpairKeepingSaved()
                        LinkService.start(this, LinkService.ACTION_PAIR, peer.service)
                    }
                }
            }
            shown(b.show())
        }
    }.start()
}

/** How long to keep listening after the first Mac answers, so a second one is listed too. */
private const val SETTLE_MS = 1_500L
