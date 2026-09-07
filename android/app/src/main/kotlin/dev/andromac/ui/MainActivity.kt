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
import android.widget.Button
import android.widget.ImageView
import android.widget.TextView
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.NetworkInfo
import dev.andromac.core.Store
import dev.andromac.feature.ClipboardBridge
import dev.andromac.feature.FindPhone
import dev.andromac.feature.MediaBridge
import dev.andromac.net.LinkService

/**
 * The single-screen home.
 *
 * Design rule: the screen shows state, not prose. Status on top, the permission card with what is
 * still missing, the four sync switches, and one row per detail screen with a one-line summary.
 */
class MainActivity : Activity() {

    private lateinit var store: Store
    private lateinit var status: TextView
    private lateinit var detail: TextView
    private lateinit var statusDot: View
    private lateinit var pairButton: Button

    private val listener: (Link.State) -> Unit = { state -> runOnUiThread { render(state) } }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        findViewById<View>(R.id.scrollRoot).padForSystemBars()
        store = Store(this)

        // The main screen is the root: no back arrow. Unpair lives on the Connection screen.
        findViewById<View>(R.id.headerBack).visibility = View.GONE
        findViewById<TextView>(R.id.headerTitle).setText(R.string.app_name)

        status = findViewById(R.id.status)
        detail = findViewById(R.id.detail)
        statusDot = findViewById(R.id.statusDot)
        pairButton = findViewById(R.id.pair)
        pairButton.setOnClickListener { onPairTapped() }

        // One row per permission, tappable to fix; the header row opens the full list.
        bindNavRow(R.id.rowPermissions) { startActivity(Intent(this, PermissionsActivity::class.java)) }
        for ((permission, rowId) in permissionRows) {
            bindNavRow(rowId) { startActivity(permission.settingsIntent(this)) }
        }
        findViewById<View>(R.id.permissionBanner).setOnClickListener { fixFirstMissing() }
        findViewById<View>(R.id.permissionDismiss).setOnClickListener {
            // Dismissal is remembered against what is missing right now, so the banner stays gone
            // for this problem and comes back if a different permission is revoked later.
            store.permissionsDismissed = Permission.missingRequired(this).joinToString(",") { it.name }
            renderPermissionBanner()
        }

        bindNavRow(R.id.rowHelp) { startActivity(Intent(this, HelpActivity::class.java)) }
        bindNavRow(R.id.rowConnection) { startActivity(Intent(this, ConnectionActivity::class.java)) }
        bindNavRow(R.id.rowNotifSettings) { startActivity(Intent(this, NotificationSettingsActivity::class.java)) }
        bindNavRow(R.id.rowClipSettings) { startActivity(Intent(this, ClipboardSettingsActivity::class.java)) }
        bindNavRow(R.id.rowUpdates) { startActivity(Intent(this, UpdateSettingsActivity::class.java)) }
        bindNavRow(R.id.rowFiles) { startActivity(Intent(this, FileSettingsActivity::class.java)) }
        bindNavRow(R.id.updateCard) { startActivity(Intent(this, UpdateSettingsActivity::class.java)) }
        // In-app language selection arrived with API 33; below that the row has nothing to open.
        if (Build.VERSION.SDK_INT >= 33) {
            bindNavRow(R.id.rowLanguage) {
                startActivity(Intent(Settings.ACTION_APP_LOCALE_SETTINGS, Uri.parse("package:$packageName")))
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

        findViewById<TextView>(R.id.version).text = getString(R.string.version_footer, versionLabel())

        // Ask for what can be asked for. Notification access has no runtime dialog, it is a
        // settings screen, so it is offered once, right after this, in [offerNotificationAccess].
        if (Build.VERSION.SDK_INT >= 33 && !Permission.POST_NOTIFICATIONS.granted(this)) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), REQ_POST_NOTIF)
        }
        LinkService.start(this)
    }

    override fun onStart() {
        super.onStart()
        Link.addListener(listener)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        render(Link.state)
        if (requestCode == REQ_POST_NOTIF) offerNotificationAccess()
    }

    override fun onResume() {
        super.onResume()
        FindPhone.stop(this)        // opening the app means they found the phone
        render(Link.state)          // permissions may have changed while away in Settings
        offerNotificationAccess()
        // At most daily, and only when the app is opened: the phone never polls (ENERGY rule 1).
        runUpdateCheckIfDue(store) {
            if (isFinishing) return@runUpdateCheckIfDue
            renderUpdate()
            offerUpdate()
        }
        offerUpdate()
    }

    /**
     * Focus is the one moment Android lets an app read the clipboard, so opening AndroMac is
     * when a copy made on the phone can reach the Mac without a tap.
     */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) ClipboardBridge(this, store).sendCurrentClipIfNew()
    }

    override fun onStop() {
        Link.removeListener(listener)
        // On rotation the dialog stayed attached to the old activity and leaked its window.
        pairingDialog?.dismiss()
        pairingDialog = null
        super.onStop()
    }

    // ---------------------------------------------------------------- rendering

    private fun render(state: Link.State) {
        val paired = store.isPaired
        val (title, dotColor) = when (state) {
            is Link.State.Connected -> R.string.state_connected to R.color.am_state_ok
            is Link.State.Searching ->
                (if (paired) R.string.state_waiting_mac else R.string.state_searching) to R.color.am_state_pending
            is Link.State.NeedsPairing -> R.string.state_waiting_approval to R.color.am_state_pending
            is Link.State.KeyChanged -> R.string.state_key_changed to R.color.am_state_alert
            Link.State.Stopped -> when {
                !paired -> R.string.state_unpaired
                !store.autoConnect -> R.string.state_auto_off
                else -> R.string.state_offline
            } to R.color.am_state_idle
        }

        status.setText(title)
        statusDot.background?.mutate()?.setTint(getColor(dotColor))

        detail.text = when (state) {
            is Link.State.Connected -> state.peerName
            is Link.State.NeedsPairing -> getString(R.string.pair_code, state.sas)
            is Link.State.KeyChanged -> getString(R.string.key_changed_tap)
            // No detail line while unpaired: the guide right below already explains it.
            else -> if (paired) store.pairedName else ""
        }

        pairButton.visibility = when (state) {
            is Link.State.Connected -> View.GONE
            is Link.State.Searching -> if (paired) View.GONE else View.VISIBLE
            Link.State.Stopped -> if (paired && !store.autoConnect) View.VISIBLE else if (paired) View.GONE else View.VISIBLE
            else -> View.VISIBLE
        }
        pairButton.setText(
            when {
                state is Link.State.NeedsPairing -> R.string.pairing_review
                state is Link.State.KeyChanged -> R.string.key_changed_review
                paired -> R.string.connection_now
                else -> R.string.pair
            }
        )

        renderOnboarding()
        renderPermissionBanner()
        renderPermissions()
        renderSummaries()
        renderUpdate()

        if (state is Link.State.NeedsPairing) confirmPairing(state.peerName, state.sas, state.peerKey)
    }

    /**
     * The connection guide. Visible only while unpaired, and it shows the LIVE state of every
     * step: which step is stuck, rather than "cannot connect".
     */
    private fun renderOnboarding() {
        val visible = !store.isPaired
        findViewById<View>(R.id.onboardingSection).visibility = if (visible) View.VISIBLE else View.GONE
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

    /**
     * The banner at the top of the screen: one line saying which required permission is missing,
     * tappable to grant it and dismissible with the cross. A mirror that relays nothing is the
     * one state worth interrupting for; the optional permissions stay in the card below.
     */
    private fun renderPermissionBanner() {
        val missing = Permission.missingRequired(this)
        val banner = findViewById<View>(R.id.permissionBanner)
        val show = missing.isNotEmpty() && store.permissionsDismissed != missing.joinToString(",") { it.name }
        banner.visibility = if (show) View.VISIBLE else View.GONE
        if (!show) return
        findViewById<TextView>(R.id.permissionBody).text = missing.joinToString(" · ") {
            getString(
                if (it == Permission.NOTIFICATION_ACCESS) R.string.permission_banner_notif_access
                else R.string.permission_banner_post
            )
        }
    }

    private fun fixFirstMissing() {
        Permission.missingRequired(this).firstOrNull()?.let { startActivity(it.settingsIntent(this)) }
    }

    /**
     * Notification access cannot be requested from code, only opened, so this offers it once,
     * with the reason. Asking at every launch would be nagging; the card is still there for later.
     */
    private fun offerNotificationAccess() {
        if (Permission.NOTIFICATION_ACCESS.granted(this) || store.notificationAccessOffered) return
        store.notificationAccessOffered = true
        AlertDialog.Builder(this)
            .setTitle(R.string.setup_notif_title)
            .setMessage(R.string.setup_notif_prompt)
            .setPositiveButton(R.string.setup_open_settings) { _, _ ->
                startActivity(Permission.NOTIFICATION_ACCESS.settingsIntent(this))
            }
            .setNegativeButton(R.string.setup_later, null)
            .show()
    }

    private val permissionRows = mapOf(
        Permission.POST_NOTIFICATIONS to R.id.rowPostNotif,
        Permission.NOTIFICATION_ACCESS to R.id.rowNotifAccess,
        Permission.BATTERY to R.id.rowBatteryOpt,
        Permission.DND to R.id.rowDnd,
        Permission.OVERLAY to R.id.rowOverlay,
    )

    /** The permission card: the summary row always, plus one row per permission still missing. */
    private fun renderPermissions() {
        val missing = Permission.missing(this)
        findViewById<TextView>(R.id.permissionsSummary).apply {
            text = Permission.summary(this@MainActivity)
            setTextColor(getColor(if (missing.isEmpty()) R.color.am_state_ok else R.color.am_state_pending))
        }
        for ((permission, rowId) in permissionRows) {
            findViewById<View>(rowId).visibility = if (permission in missing) View.VISIBLE else View.GONE
        }
    }

    /** The summaries under the detail rows: what is configured, visible without opening the screen. */
    private fun renderSummaries() {
        findViewById<TextView>(R.id.connectionSummary).text = when {
            !store.isPaired -> getString(R.string.state_unpaired)
            store.autoConnect -> getString(R.string.connection_summary_auto, store.pairedName)
            else -> getString(R.string.connection_summary_manual, store.pairedName)
        }
        findViewById<TextView>(R.id.notifSummary).text = store.appFilterSummary(this)

        val clipParts = buildList {
            add(getString(if (store.clipboardAutoPaste) R.string.clip_summary_auto else R.string.clip_summary_notify_only))
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

    /**
     * "AndroMac 1.1.0 is available": Install now, Later, or Skip this version.
     *
     * Asked once per launch and once per release: a skipped release never comes back, and the
     * Updates screen still has the button for whoever changes their mind.
     */
    private fun offerUpdate() {
        if (updateOffered || isFinishing) return
        val release = store.newerRelease(currentVersion(), currentCommit()) ?: return
        if (release.label == store.updateSkipped) return
        updateOffered = true
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.update_available_title, release.label))
            .setMessage(
                if (release.apk == null) getString(R.string.update_available_page)
                else getString(R.string.update_available_body)
            )
            .setPositiveButton(
                if (release.apk == null) R.string.update_open_page else R.string.update_install_now
            ) { _, _ ->
                if (release.apk == null) openReleasePage(release.url)
                else startUpdateInstall(store) { if (!isFinishing) renderUpdate() }
            }
            .setNegativeButton(R.string.update_later, null)
            .setNeutralButton(R.string.update_skip) { _, _ -> store.updateSkipped = release.label }
            .show()
    }

    private var updateOffered = false

    // ---------------------------------------------------------------- pairing

    private var pairingDialog: AlertDialog? = null

    private fun onPairTapped() {
        when (val s = Link.state) {
            is Link.State.NeedsPairing -> confirmPairing(s.peerName, s.sas, s.peerKey)
            is Link.State.KeyChanged -> warnKeyChange(s.peerName, s.sas)
            else -> LinkService.start(this, if (store.isPaired) LinkService.ACTION_CONNECT else LinkService.ACTION_PAIR)
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

    private companion object {
        const val REQ_POST_NOTIF = 1
    }
}
