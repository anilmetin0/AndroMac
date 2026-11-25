package dev.andromac.ui

import android.app.Activity
import android.app.AlertDialog
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.MacPick
import dev.andromac.core.Store
import dev.andromac.net.Discovery
import dev.andromac.net.LinkService

/**
 * Pair: one dialog that searches, then lists every Mac that answered with its address, and dials
 * only the one the user picks, even when it is the only one. A Mac saved on this phone under the
 * same name is switched to instead of paired again. [shown] gets the dialog, so the screen can
 * dismiss it in onStop. Search again searches in the same dialog.
 *
 * The browse runs here rather than in the link loop: picking needs a list, not a connection.
 * Known limit: on API 29-33 it can collide with a browse the service runs at the same moment
 * (paired and searching), and a resolve there may fail; Search again covers it.
 */
fun Activity.pickMac(store: Store, shown: (AlertDialog) -> Unit) {
    val view = layoutInflater.inflate(R.layout.dialog_mac_picker, null)
    val status = view.findViewById<View>(R.id.pickerStatus)
    val spinner = view.findViewById<View>(R.id.pickerSpinner)
    val message = view.findViewById<TextView>(R.id.pickerMessage)
    val list = view.findViewById<LinearLayout>(R.id.pickerList)
    val dialog = AlertDialog.Builder(this)
        .setView(view)
        .setNeutralButton(R.string.pair_search_again, null)
        .setNegativeButton(android.R.string.cancel, null)
        .create()

    fun pick(peer: MacPick.Peer, peers: List<MacPick.Peer>) {
        dialog.dismiss()
        // Name and address first. A name alone decides only when no other row carries
        // it: two Macs with one name would otherwise switch to the one not tapped.
        val ip = peer.host.hostAddress
        val saved = store.savedMacs.firstOrNull { it.name == peer.name && it.host == ip }
            ?: store.savedMacs.firstOrNull { it.name == peer.name }
                ?.takeIf { peers.count { p -> p.name == peer.name } == 1 }
        if (saved != null) {
            store.activate(saved)
            store.lastEndpoint = "${peer.host.hostAddress}:${peer.port}"
            LinkService.start(this, LinkService.ACTION_SWITCH)
        } else {
            store.unpairKeepingSaved()
            LinkService.start(this, LinkService.ACTION_PAIR, peer.service)
        }
    }

    fun search() {
        val again = dialog.getButton(AlertDialog.BUTTON_NEUTRAL)
        again.isEnabled = false
        list.visibility = View.GONE
        list.removeAllViews()
        status.visibility = View.VISIBLE
        spinner.visibility = View.VISIBLE
        message.setText(R.string.pair_searching)
        Thread {
            // One row per Mac: a Mac on two interfaces answers twice under one service name.
            val peers = Discovery(this).browse(settleMs = SETTLE_MS) { it.isNotEmpty() }.distinctBy { it.service }
            Link.macSeenOnNetwork = peers.isNotEmpty()
            runOnUiThread {
                if (!dialog.isShowing || isFinishing || isDestroyed) return@runOnUiThread
                again.isEnabled = true
                spinner.visibility = View.GONE
                if (peers.isEmpty()) {
                    message.setText(R.string.onboarding_step1_missing)
                    return@runOnUiThread
                }
                status.visibility = View.GONE
                list.visibility = View.VISIBLE
                for (peer in peers) {
                    val row = layoutInflater.inflate(R.layout.item_mac, list, false)
                    row.findViewById<ImageView>(R.id.macIcon).visibility = View.VISIBLE
                    row.findViewById<TextView>(R.id.macName).text = peer.name
                    row.findViewById<TextView>(R.id.macDetail).text = peer.host.hostAddress
                    row.findViewById<View>(R.id.macActive).visibility = View.GONE
                    row.setOnClickListener { pick(peer, peers) }
                    list.addView(row)
                }
            }
        }.start()
    }

    dialog.setOnShowListener {
        // Set here, not on the builder: a builder's button always closes the dialog.
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener { search() }
        search()
    }
    dialog.show()
    shown(dialog)
}

/** How long to keep listening after the first Mac answers, so a second one is listed too. */
private const val SETTLE_MS = 1_500L
