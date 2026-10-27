package dev.andromac.ui

import android.app.Activity
import android.app.AlertDialog
import android.app.LocaleManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.Switch
import android.widget.TextView
import dev.andromac.R
import dev.andromac.core.Store
import dev.andromac.feature.MediaBridge
import dev.andromac.feature.UpdateCheck

/**
 * Every detail screen in one place, each row with a one-line summary of what is set there:
 * Connection, Features, App, Help, then Reset. The main screen keeps state and the everyday
 * switches; Features repeats those switches so every feature is found in one list.
 */
class SettingsActivity : Activity() {

    private lateinit var store: Store

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_settings, R.string.settings_title)
        store = Store(this)

        bindNavRow(R.id.rowConnection) { open(ConnectionActivity::class.java) }
        bindNavRow(R.id.rowNotifSettings) { open(NotificationSettingsActivity::class.java) }
        bindNavRow(R.id.rowClipSettings) { open(ClipboardSettingsActivity::class.java) }
        bindSwitchRow(R.id.rowMedia, R.id.swMedia, store.syncMedia) {
            if (it == store.syncMedia) return@bindSwitchRow     // onResume re-reading it is no change
            store.syncMedia = it
            MediaBridge.settingChanged()      // apply immediately if connected, do not wait for a reconnect
        }
        bindSwitchRow(R.id.rowBattery, R.id.swBattery, store.syncBattery) { store.syncBattery = it }
        bindNavRow(R.id.rowFiles) { open(FileSettingsActivity::class.java) }
        // Missing, the row asks for Nearby devices; granted, it opens the Bluetooth pairings.
        bindNavRow(R.id.rowCalls) {
            if (!Permission.BLUETOOTH_CONNECT.granted(this)) grant(Permission.BLUETOOTH_CONNECT)
            else runCatching { startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) }
        }
        bindNavRow(R.id.rowPermissions) { open(PermissionsActivity::class.java) }
        bindNavRow(R.id.rowUpdates) { open(UpdateSettingsActivity::class.java) }
        // In-app language selection arrived with API 33; below that the row has nothing to open.
        if (Build.VERSION.SDK_INT >= 33) {
            bindNavRow(R.id.rowLanguage) {
                startActivity(Intent(Settings.ACTION_APP_LOCALE_SETTINGS, Uri.parse("package:$packageName")))
            }
        } else {
            findViewById<View>(R.id.rowLanguage).visibility = View.GONE
        }
        bindNavRow(R.id.rowSetup) { open(OnboardingActivity::class.java) }
        bindNavRow(R.id.rowHelp) { open(HelpActivity::class.java) }
        findViewById<TextView>(R.id.versionSummary).text = getString(R.string.version_footer, versionLabel())
        findViewById<View>(R.id.rowSource).setOnClickListener { openReleasePage("https://github.com/${UpdateCheck.REPO}") }
        bindNavRow(R.id.rowReset) {
            AlertDialog.Builder(this)
                .setTitle(R.string.reset_title)
                .setMessage(R.string.reset_confirm)
                .setPositiveButton(R.string.reset_action) { _, _ -> Store.resetEverything(this) }
                .setNegativeButton(android.R.string.cancel, null)
                .show()
        }
    }

    /** Summaries are re-read on return: a detail screen may have changed them. */
    override fun onResume() {
        super.onResume()
        text(R.id.connectionSummary, when {
            !store.isPaired -> getString(R.string.state_unpaired)
            store.autoConnect -> getString(R.string.connection_summary_auto, store.pairedName)
            else -> getString(R.string.connection_summary_manual, store.pairedName)
        })
        // The main switch off says so first: the details below it do nothing then.
        text(R.id.notifSummary,
            if (!store.syncNotifications) getString(R.string.summary_off) else store.appFilterSummary(this))
        text(R.id.clipSummary, if (!store.syncClipboard) getString(R.string.summary_off) else buildList {
            add(getString(if (store.clipboardAutoPaste) R.string.clip_summary_auto else R.string.clip_summary_notify_only))
            if (store.clipboardSkipSensitive) add(getString(R.string.clip_summary_sensitive))
        }.joinToString(" · "))
        findViewById<Switch>(R.id.swMedia).isChecked = store.syncMedia
        findViewById<Switch>(R.id.swBattery).isChecked = store.syncBattery
        text(R.id.fileSummary, getString(when {
            !store.fileTransfer -> R.string.summary_off
            store.fileAutoAccept -> R.string.file_summary_auto
            else -> R.string.file_summary_ask
        }))
        text(R.id.callsSummary, getString(
            if (Permission.BLUETOOTH_CONNECT.granted(this)) R.string.calls_summary_ready else R.string.calls_summary_allow
        ))
        text(R.id.permissionsSummary, Permission.summary(this))
        text(R.id.updatesSummary,
            if (!store.updateCheck) getString(R.string.summary_off) else updateStatus(store))
        if (Build.VERSION.SDK_INT >= 33) {
            val locales = getSystemService(LocaleManager::class.java).applicationLocales
            text(R.id.languageSummary,
                if (locales.isEmpty) getString(R.string.language_system)
                else locales[0].getDisplayName(locales[0]).replaceFirstChar(Char::uppercase))
        }
    }

    private fun text(id: Int, value: String) { findViewById<TextView>(id).text = value }

    private fun open(screen: Class<out Activity>) = startActivity(Intent(this, screen))
}
