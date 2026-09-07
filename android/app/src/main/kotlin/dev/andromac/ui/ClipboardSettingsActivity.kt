package dev.andromac.ui

import android.app.Activity
import android.os.Bundle
import android.widget.TextView
import android.widget.Toast
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Store

/** Clipboard detail settings. Split out so the main screen stays uncluttered. */
class ClipboardSettingsActivity : Activity() {

    private lateinit var store: Store

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_clipboard, R.string.clip_title)
        store = Store(this)

        bindSwitchRow(R.id.rowAutoPaste, R.id.swAutoPaste, store.clipboardAutoPaste) {
            store.clipboardAutoPaste = it
            refresh()
        }
        bindSwitchRow(R.id.rowNotify, R.id.swNotify, store.clipboardNotify) {
            store.clipboardNotify = it
        }
        bindSwitchRow(R.id.rowSensitive, R.id.swSensitive, store.clipboardSkipSensitive) {
            store.clipboardSkipSensitive = it
        }

        bindNavRow(R.id.rowSendNow) {
            if (!Link.isConnected) {
                Toast.makeText(this, R.string.clip_send_offline, Toast.LENGTH_SHORT).show()
            } else {
                startActivity(ClipHelperActivity.getIntent(this))
            }
        }
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        // With auto-paste off, the notification is the only way in: it must not be turned off.
        setRowEnabled(R.id.rowNotify, store.clipboardAutoPaste)
        findViewById<TextView>(R.id.sendNowSummary).setText(
            if (Link.isConnected) R.string.clip_send_ready else R.string.clip_send_offline
        )
    }
}
