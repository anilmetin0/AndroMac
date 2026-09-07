package dev.andromac.ui

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.TextView
import dev.andromac.R
import dev.andromac.core.Store

/** Notification detail settings. Split out so the main screen stays uncluttered. */
class NotificationSettingsActivity : Activity() {

    private lateinit var store: Store

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_notifications, R.string.notif_title)
        store = Store(this)

        bindNavRow(R.id.rowAppFilter) { startActivity(Intent(this, AppsActivity::class.java)) }
        bindSwitchRow(R.id.rowSilent, R.id.swSilent, store.syncSilentNotifications) {
            store.syncSilentNotifications = it
        }
        bindSwitchRow(R.id.rowOnlyLocked, R.id.swOnlyLocked, store.onlyWhenLocked) {
            store.onlyWhenLocked = it
        }
    }

    override fun onResume() {
        super.onResume()
        findViewById<TextView>(R.id.appFilterSummary).text = store.appFilterSummary(this)
    }
}
