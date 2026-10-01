package dev.andromac.ui

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.view.View
import android.widget.TextView
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Store
import dev.andromac.net.LinkService

/**
 * The link to the Mac: its state, whether the phone reconnects on its own, and the way out.
 *
 * Reconnecting is the service's job and needs no switch to work; the switch exists for the
 * person who wants the phone to stay off the Mac for a while without forgetting it.
 */
class ConnectionActivity : Activity() {

    private lateinit var store: Store
    private val listener: (Link.State) -> Unit = { runOnUiThread { render() } }

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
        bindNavRow(R.id.rowUnpair) { confirmUnpair() }
    }

    override fun onStart() {
        super.onStart()
        Link.addListener(listener)
    }

    override fun onStop() {
        Link.removeListener(listener)
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
        findViewById<TextView>(R.id.connectionAddress).text =
            store.lastEndpoint?.substringBeforeLast(':') ?: getString(R.string.diag_none)
        val connected = state is Link.State.Connected
        findViewById<TextView>(R.id.rowConnectNow)
            .setText(if (connected) R.string.link_disconnect else R.string.connection_now)
        setRowEnabled(R.id.rowConnectNow, paired)
        // Disconnect turns auto-connect off from outside this screen; the switch follows.
        findViewById<android.widget.Switch>(R.id.swAuto).isChecked = store.autoConnect
        findViewById<View>(R.id.unpairCard).visibility = if (paired) View.VISIBLE else View.GONE
    }

    private fun confirmUnpair() {
        AlertDialog.Builder(this)
            .setTitle(R.string.unpair)
            .setMessage(R.string.unpair_confirm)
            .setPositiveButton(R.string.unpair) { _, _ ->
                store.unpair()
                LinkService.start(this)
                finish()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }
}
