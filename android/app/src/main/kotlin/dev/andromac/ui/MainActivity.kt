package dev.andromac.ui

import android.app.Activity
import android.app.AlertDialog
import android.app.LocaleManager
import android.app.NotificationManager
import android.content.ComponentName
import android.content.pm.PackageManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.Menu
import android.view.View
import android.widget.Button
import android.widget.PopupMenu
import android.widget.TextView
import dev.andromac.R
import android.widget.ImageView
import dev.andromac.core.Link
import dev.andromac.core.NetworkInfo
import dev.andromac.core.Store
import dev.andromac.feature.FindPhone
import dev.andromac.feature.NotificationRelay
import dev.andromac.feature.MediaBridge
import dev.andromac.net.LinkService

/**
 * The single-screen settings surface.
 *
 * Design rule: **finished work disappears from the screen.** The setup section is shown only
 * while a permission is missing; once everything is granted the screen shrinks to the status
 * plus the toggles.
 */
class MainActivity : Activity() {

    private lateinit var store: Store
    private lateinit var status: TextView
    private lateinit var detail: TextView
    private lateinit var statusDot: View
    private lateinit var pairButton: Button
    private lateinit var headerAction: View

    private val listener: (Link.State) -> Unit = { state -> runOnUiThread { render(state) } }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        findViewById<View>(R.id.scrollRoot).padForSystemBars()
        store = Store(this)

        // The main screen is the root: no back arrow, and the overflow menu appears once paired.
        findViewById<View>(R.id.headerBack).visibility = View.GONE
        findViewById<TextView>(R.id.headerTitle).setText(R.string.app_name)
        headerAction = findViewById(R.id.headerAction)
        headerAction.setOnClickListener { showOverflow(it) }

        status = findViewById(R.id.status)
        detail = findViewById(R.id.detail)
        statusDot = findViewById(R.id.statusDot)
        pairButton = findViewById(R.id.pair)

        pairButton.setOnClickListener { onPairTapped() }

        findViewById<View>(R.id.rowPostNotif).setOnClickListener {
            startActivity(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            )
        }
        findViewById<View>(R.id.rowNotifAccess).setOnClickListener {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }
        findViewById<View>(R.id.rowBatteryOpt).setOnClickListener { requestIgnoreBatteryOptimizations() }
        bindNavRow(R.id.rowHelp) { startActivity(Intent(this, HelpActivity::class.java)) }
        bindNavRow(R.id.rowNotifSettings) {
            startActivity(Intent(this, NotificationSettingsActivity::class.java))
        }
        bindNavRow(R.id.rowClipSettings) {
            startActivity(Intent(this, ClipboardSettingsActivity::class.java))
        }
        bindNavRow(R.id.rowUpdates) {
            startActivity(Intent(this, UpdateSettingsActivity::class.java))
        }
        bindNavRow(R.id.rowFiles) {
            startActivity(Intent(this, FileSettingsActivity::class.java))
        }
        findViewById<View>(R.id.updateCard).setOnClickListener {
            store.updateFound?.url?.let(::openReleasePage)
        }
        // In-app language selection arrived with API 33; below that the row has nothing to open.
        if (Build.VERSION.SDK_INT >= 33) {
            bindNavRow(R.id.rowLanguage) {
                startActivity(
                    Intent(Settings.ACTION_APP_LOCALE_SETTINGS, Uri.parse("package:$packageName"))
                )
            }
        } else {
            findViewById<View>(R.id.rowLanguage).visibility = View.GONE
        }

        bindSwitchRow(R.id.rowBattery, R.id.swBattery, store.syncBattery) { store.syncBattery = it }
        bindSwitchRow(R.id.rowClipboard, R.id.swClipboard, store.syncClipboard) { store.syncClipboard = it }
        bindSwitchRow(R.id.rowNotifications, R.id.swNotifications, store.syncNotifications) {
            store.syncNotifications = it
        }
        bindSwitchRow(R.id.rowMedia, R.id.swMedia, store.syncMedia) {
            store.syncMedia = it
            MediaBridge.settingChanged()      // apply immediately if connected, do not wait for a reconnect
        }

        findViewById<TextView>(R.id.version).text =
            getString(R.string.version_footer, versionLabel())

        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        LinkService.start(this)
    }

    override fun onStart() {
        super.onStart()
        Link.addListener(listener)
    }

    override fun onResume() {
        super.onResume()
        FindPhone.stop(this)        // opening the app means they found the phone
        render(Link.state)          // permissions may have changed while away in Settings
        // Opt-in and at most daily: the phone never polls for this on its own (ENERGY rule 1).
        runUpdateCheckIfDue(store) { if (!isFinishing) renderUpdate() }
    }

    override fun onStop() {
        Link.removeListener(listener)
        // On rotation the dialog stayed attached to the old activity and leaked its window.
        pairingDialog?.dismiss()
        pairingDialog = null
        super.onStop()
    }

    /** Stands in for the ActionBar overflow menu: the right-hand button of our own header. */
    private fun showOverflow(anchor: View) {
        PopupMenu(this, anchor).apply {
            menu.add(Menu.NONE, 0, Menu.NONE, R.string.unpair)
            setOnMenuItemClickListener { confirmUnpair(); true }
            show()
        }
    }

    private fun confirmUnpair() {
        AlertDialog.Builder(this)
            .setTitle(R.string.unpair)
            .setMessage(R.string.unpair_confirm)
            .setPositiveButton(R.string.unpair) { _, _ ->
                store.unpair()
                LinkService.start(this)
                render(Link.state)
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    // ---------------------------------------------------------------- rendering

    private fun render(state: Link.State) {
        val (title, dotColor) = when (state) {
            is Link.State.Connected -> getString(R.string.state_connected) to R.color.am_state_ok
            is Link.State.Searching -> getString(R.string.state_searching) to R.color.am_state_pending
            is Link.State.NeedsPairing ->
                getString(R.string.state_waiting_approval) to R.color.am_state_pending
            is Link.State.KeyChanged -> getString(R.string.state_key_changed) to R.color.am_state_alert
            Link.State.Stopped ->
                if (store.isPaired) getString(R.string.state_offline) to R.color.am_state_idle
                else getString(R.string.state_unpaired) to R.color.am_state_idle
        }

        status.text = title
        statusDot.background?.mutate()?.setTint(getColor(dotColor))

        detail.text = when (state) {
            is Link.State.Connected -> state.peerName
            is Link.State.NeedsPairing -> getString(R.string.pair_code, state.sas)
            is Link.State.KeyChanged -> getString(R.string.key_changed_tap)
            // No detail line while unpaired: the guide right below already explains it.
            else -> if (store.isPaired) store.pairedName else ""
        }

        pairButton.visibility = when (state) {
            is Link.State.Connected -> View.GONE
            is Link.State.Searching -> if (store.isPaired) View.GONE else View.VISIBLE
            else -> View.VISIBLE
        }
        pairButton.text = when (state) {
            is Link.State.NeedsPairing -> getString(R.string.pair_code, state.sas)
            is Link.State.KeyChanged -> getString(R.string.key_changed_review)
            else -> getString(R.string.pair)
        }

        headerAction.visibility = if (store.isPaired) View.VISIBLE else View.GONE

        renderOnboarding()
        renderSetup()
        renderSummaries()
        renderUpdate()

        if (state is Link.State.NeedsPairing) confirmPairing(state.peerName, state.sas, state.peerKey)
    }

    /**
     * The connection guide. Visible only while unpaired, and it shows the LIVE state of every
     * step — instead of saying "cannot connect" it says which step is stuck.
     */
    private fun renderOnboarding() {
        val visible = !store.isPaired
        findViewById<View>(R.id.onboardingSection).visibility =
            if (visible) View.VISIBLE else View.GONE
        if (!visible) return

        val macSeen = Link.macSeenOnNetwork
        step(R.id.step1Icon, R.id.step1Status, macSeen,
            getString(if (macSeen) R.string.onboarding_step1_found else R.string.onboarding_step1_missing))

        val ip = NetworkInfo.localIpv4()
        step(R.id.step2Icon, R.id.step2Status, ip != null,
            if (ip != null) getString(R.string.onboarding_step2_ok, ip)
            else getString(R.string.onboarding_step2_none))

        val ready = macSeen && ip != null
        step(R.id.step3Icon, R.id.step3Status, false,
            getString(if (ready) R.string.onboarding_step3_ready else R.string.onboarding_step3_waiting))
    }

    private fun step(iconId: Int, statusId: Int, done: Boolean, status: String) {
        findViewById<ImageView>(iconId).setImageResource(
            if (done) R.drawable.ic_step_done else R.drawable.ic_step_pending
        )
        findViewById<TextView>(statusId).text = status
    }

    /** The setup section is shown only while there is something left to do. */
    private fun renderSetup() {
        val notifOk = hasNotificationAccess()
        val batteryOk = isIgnoringBatteryOptimizations()
        val postOk = canPostNotifications()
        findViewById<View>(R.id.rowPostNotif).visibility = if (postOk) View.GONE else View.VISIBLE
        findViewById<View>(R.id.rowNotifAccess).visibility = if (notifOk) View.GONE else View.VISIBLE
        findViewById<View>(R.id.rowBatteryOpt).visibility = if (batteryOk) View.GONE else View.VISIBLE
        findViewById<View>(R.id.setupSection).visibility =
            if (notifOk && batteryOk && postOk) View.GONE else View.VISIBLE
    }

    /** The summaries under the detail rows: what is configured, visible without opening the screen. */
    private fun renderSummaries() {
        findViewById<TextView>(R.id.notifSummary).text = store.appFilterSummary(this)

        val clipParts = buildList {
            add(
                getString(
                    if (store.clipboardAutoPaste) R.string.clip_summary_auto
                    else R.string.clip_summary_notify_only
                )
            )
            if (store.clipboardSkipSensitive) add(getString(R.string.clip_summary_sensitive))
        }
        findViewById<TextView>(R.id.clipSummary).text = clipParts.joinToString(" · ")

        findViewById<TextView>(R.id.fileSummary).setText(
            when {
                !store.fileTransfer -> R.string.file_summary_off
                store.fileAutoAccept -> R.string.file_summary_auto
                else -> R.string.file_summary_ask
            }
        )

        if (Build.VERSION.SDK_INT >= 33) {
            val locales = getSystemService(LocaleManager::class.java).applicationLocales
            findViewById<TextView>(R.id.languageSummary).text =
                if (locales.isEmpty) getString(R.string.language_system)
                else locales[0].getDisplayName(locales[0]).replaceFirstChar(Char::uppercase)
        }
    }

    /** The update card and the Updates row summary. Both read the stored result, no request here. */
    private fun renderUpdate() {
        val newer = store.newerRelease(currentVersion(), currentCommit())
        findViewById<View>(R.id.updateCard).visibility = if (newer == null) View.GONE else View.VISIBLE
        if (newer != null) {
            findViewById<TextView>(R.id.updateBody).text = getString(R.string.update_card_body, newer.label)
        }
        findViewById<TextView>(R.id.updatesSummary).text =
            if (!store.updateCheck) getString(R.string.updates_summary_off)
            else updateStatus(store)
    }

    // ---------------------------------------------------------------- pairing

    private var pairingDialog: AlertDialog? = null

    private fun onPairTapped() {
        when (val s = Link.state) {
            is Link.State.NeedsPairing -> confirmPairing(s.peerName, s.sas, s.peerKey)
            is Link.State.KeyChanged -> warnKeyChange(s.peerName, s.sas)
            else -> {
                LinkService.start(this, LinkService.ACTION_PAIR)
                status.text = getString(R.string.state_searching)
            }
        }
    }

    private fun confirmPairing(peerName: String, sas: String, key: ByteArray) {
        if (pairingDialog?.isShowing == true) return
        pairingDialog = AlertDialog.Builder(this)
            .setView(pairingView(R.string.pairing_title, null, peerName, sas, getString(R.string.pairing_question)))
            .setPositiveButton(R.string.pair) { _, _ ->
                store.pairedKey = key
                store.pairedName = peerName
                LinkService.start(this)
            }
            .setNegativeButton(R.string.pairing_reject) { _, _ ->
                store.unpair()
                LinkService.start(this)      // otherwise the worker stays parked in await(0)
            }
            .setCancelable(false)
            .show()
    }

    private fun warnKeyChange(peerName: String, sas: String) {
        AlertDialog.Builder(this)
            .setView(
                pairingView(
                    R.string.key_changed_title, R.color.am_state_alert, peerName, sas,
                    getString(R.string.key_changed_body, peerName),
                )
            )
            .setPositiveButton(R.string.key_changed_reset) { _, _ ->
                store.unpair()
                LinkService.start(this, LinkService.ACTION_PAIR)
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    /** Both dialogs share the same body; only the title text and color differ. */
    @Suppress("InflateParams")      // the dialog body has no root, so a null parent is correct
    private fun pairingView(
        titleRes: Int, titleColor: Int?, peerName: String, sas: String, note: String,
    ): View = layoutInflater.inflate(R.layout.dialog_pairing, null).apply {
        findViewById<TextView>(R.id.pairTitle).apply {
            setText(titleRes)
            if (titleColor != null) setTextColor(getColor(titleColor))
        }
        findViewById<TextView>(R.id.pairPeer).text = peerName
        // "123456" -> "123 456": the eye reads three digits at a time, so comparing goes faster.
        // A key-changed warning has no code (the attempt stops before one exists, PROTOCOL §3).
        findViewById<TextView>(R.id.pairCode).apply {
            text = sas.chunked(3).joinToString(" ")
            visibility = if (sas.isEmpty()) View.GONE else View.VISIBLE
        }
        findViewById<TextView>(R.id.pairNote).text = note
    }

    // ---------------------------------------------------------------- permissions

    /**
     * A substring match is NOT enough: the release package is `dev.andromac` and the debug
     * package is `dev.andromac.debug`. With only the debug variant enabled, release used to
     * report the access as "granted".
     */
    private fun hasNotificationAccess(): Boolean =
        getSystemService(NotificationManager::class.java)
            .isNotificationListenerAccessGranted(ComponentName(this, NotificationRelay::class.java))

    /** Before API 33 there is no such permission; there it always counts as granted. */
    private fun canPostNotifications(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun isIgnoringBatteryOptimizations(): Boolean =
        getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)

    @Suppress("BatteryLife")
    private fun requestIgnoreBatteryOptimizations() {
        startActivity(
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
        )
    }

}
