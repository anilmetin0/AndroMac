package dev.andromac.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Store
import dev.andromac.net.LinkService

/**
 * The link to the Mac: its state, the saved Macs to switch between, whether the phone
 * reconnects on its own, and the way out.
 *
 * Reconnecting is the service's job and needs no switch to work; the switch exists for the
 * person who wants the phone to stay off the Mac for a while without forgetting it.
 */
class ConnectionActivity : Activity() {

    private lateinit var store: Store
    private var pickerDialog: AlertDialog? = null
    /** A new pairing's code is confirmed on the main screen, so this one steps aside for it. */
    private val listener: (Link.State) -> Unit = { s ->
        runOnUiThread {
            if (s !is Link.State.NeedsPairing) render()
            else startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_connection, R.string.connection_title)
        store = Store(this)

        bindSwitchRow(R.id.rowAuto, R.id.swAuto, store.autoConnect) {
            store.autoConnect = it
            LinkService.start(this)          // wakes the loop so the new value applies now
            render()
        }
        // Connected, the row is the way off: the same Disconnect as the notification and the tile.
        bindNavRow(R.id.rowConnectNow) {
            LinkService.start(this, if (Link.isConnected) LinkService.ACTION_DISCONNECT else LinkService.ACTION_CONNECT)
        }
        bindNavRow(R.id.rowUnpair) { store.activeMac?.let(::confirmForget) }
        bindNavRow(R.id.rowAddMac) { if (pickerDialog?.isShowing != true) pickMac(store) { pickerDialog = it } }
    }

    override fun onStart() {
        super.onStart()
        Link.addListener(listener)
    }

    override fun onStop() {
        Link.removeListener(listener)
        pickerDialog?.dismiss()
        pickerDialog = null
        super.onStop()
    }

    private fun render() {
        val state = Link.state
        val paired = store.isPaired
        findViewById<TextView>(R.id.connectionState).setText(
            when {
                state is Link.State.Connected -> R.string.state_connected
                state is Link.State.Searching -> R.string.state_waiting_mac
                !paired -> R.string.state_unpaired
                !store.autoConnect -> R.string.state_auto_off
                else -> R.string.state_offline
            }
        )
        findViewById<TextView>(R.id.connectionMac).text =
            store.pairedName.ifEmpty { getString(R.string.diag_none) }
        val active = store.activeMac
        findViewById<TextView>(R.id.connectionAddress).text =
            store.lastEndpoint?.substringBeforeLast(':') ?: active?.host?.ifEmpty { null } ?: getString(R.string.diag_none)
        val connected = state is Link.State.Connected
        val seen = active?.lastSeen?.takeIf { it > 0 && !connected }
        findViewById<View>(R.id.rowLastSeen).visibility = if (seen != null) View.VISIBLE else View.GONE
        if (seen != null) findViewById<TextView>(R.id.connectionLastSeen).text = ago(seen)
        renderMacs(active, connected)
        findViewById<TextView>(R.id.rowConnectNow)
            .setText(if (connected) R.string.link_disconnect else R.string.connection_now)
        setRowEnabled(R.id.rowConnectNow, paired)
        // Disconnect turns auto-connect off from outside this screen; the switch follows.
        findViewById<android.widget.Switch>(R.id.swAuto).isChecked = store.autoConnect
        findViewById<View>(R.id.unpairCard).visibility = if (paired) View.VISIBLE else View.GONE
    }

    /** One row per saved Mac: name, address and last seen, the active one marked. */
    private fun renderMacs(active: Store.SavedMac?, connected: Boolean) {
        val list = findViewById<LinearLayout>(R.id.macList)
        list.removeAllViews()
        for (mac in store.savedMacs) {
            val isActive = mac.key == active?.key
            val row = layoutInflater.inflate(R.layout.item_mac, list, false)
            row.findViewById<TextView>(R.id.macName).text = mac.name.ifEmpty { getString(R.string.diag_none) }
            val seen = if (isActive && connected || mac.lastSeen <= 0) null
                else getString(R.string.mac_last_seen, ago(mac.lastSeen))
            row.findViewById<TextView>(R.id.macDetail).apply {
                text = listOfNotNull(mac.host.ifEmpty { null }, seen).joinToString(" · ")
                visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
            }
            row.findViewById<View>(R.id.macActive).visibility = if (isActive) View.VISIBLE else View.GONE
            row.setOnClickListener {
                if (isActive) return@setOnClickListener
                store.activate(mac)
                LinkService.start(this, LinkService.ACTION_SWITCH)
                render()
            }
            row.setOnLongClickListener { confirmForget(mac); true }
            list.addView(row)
        }
    }

    private fun confirmForget(mac: Store.SavedMac) {
        val active = mac.key == store.activeMac?.key
        AlertDialog.Builder(this)
            .setTitle(R.string.unpair)
            .setMessage(if (active) getString(R.string.unpair_confirm) else getString(R.string.mac_forget_confirm, mac.name))
            .setPositiveButton(R.string.unpair) { _, _ ->
                store.forget(mac)
                // The active one: its live link goes too, and the loop parks unpaired.
                LinkService.start(this, if (active) LinkService.ACTION_SWITCH else null)
                if (store.savedMacs.isEmpty()) finish() else render()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }
}
