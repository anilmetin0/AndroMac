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
        findViewById<View>(R.id.rowDnd).setOnClickListener { openDndAccess() }
        findViewById<View>(R.id.rowOverlay).setOnClickListener { openOverlayAccess() }
        findViewById<View>(R.id.permissionBanner).setOnClickListener { fixFirstMissing() }
        findViewById<View>(R.id.permissionDismiss).setOnClickListener {
            // Dismissal is remembered against what is missing right now, so the banner stays gone
            // for this problem and comes back if a different permission is revoked later.
            store.permissionsDismissed = missingRequired().joinToString(",")
            renderPermissionBanner()
        }
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
            startActivity(Intent(this, UpdateSettingsActivity::class.java))
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

        // Ask for what can be asked for. Notification access has no runtime dialog — it is a
        // settings screen — so it is offered once, right after this, in [offerNotificationAccess].
        if (Build.VERSION.SDK_INT >= 33 && !canPostNotifications()) {
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
        renderPermissionBanner()
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

    /**
     * The banner at the top of the screen: one line saying which permission is missing, tappable to
     * grant it and dismissible with the cross.
     *
     * It exists because the setup section sits below the fold once the screen fills up, and a
     * mirror that quietly relays nothing is the single worst state this app can be in. Only the
     * two permissions the app cannot work without appear here; everything optional stays in the
     * setup list.
     */
    private fun renderPermissionBanner() {
        val missing = missingRequired()
        val banner = findViewById<View>(R.id.permissionBanner)
        val show = missing.isNotEmpty() && store.permissionsDismissed != missing.joinToString(",")
        banner.visibility = if (show) View.VISIBLE else View.GONE
        if (!show) return
        findViewById<TextView>(R.id.permissionBody).text = missing.joinToString(" · ") {
            getString(
                if (it == PERM_NOTIF_ACCESS) R.string.permission_banner_notif_access
                else R.string.permission_banner_post
            )
        }
    }

    /** Which of the two permissions the app truly needs are not granted, in the order to fix them. */
    private fun missingRequired(): List<String> = buildList {
        if (!canPostNotifications()) add(PERM_POST)
        if (!hasNotificationAccess()) add(PERM_NOTIF_ACCESS)
    }

    private fun fixFirstMissing() {
        when (missingRequired().firstOrNull()) {
            PERM_POST -> startActivity(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            )
            PERM_NOTIF_ACCESS -> startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            else -> Unit
        }
    }

    /**
     * Notification access cannot be requested from code, only opened, so this offers it once —
     * with the reason — instead of leaving the user to find the row on their own. Asking again at
     * every launch would be nagging, and the setup row is still there for later.
     */
    private fun offerNotificationAccess() {
        if (hasNotificationAccess() || store.notificationAccessOffered) return
        store.notificationAccessOffered = true
        AlertDialog.Builder(this)
            .setTitle(R.string.setup_notif_title)
            .setMessage(R.string.setup_notif_prompt)
            .setPositiveButton(R.string.setup_open_settings) { _, _ ->
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            }
            .setNegativeButton(R.string.setup_later, null)
            .show()
    }

    /** The setup section is shown only while there is something left to do. */
    private fun renderSetup() {
        val notifOk = hasNotificationAccess()
        val batteryOk = isIgnoringBatteryOptimizations()
        val postOk = canPostNotifications()
        // Optional, and named as such in their subtitles: one lets the Mac silence the phone, the
        // other lets it read the clipboard without the user tapping a notification first.
        val dndOk = hasDndAccess()
        val overlayOk = Settings.canDrawOverlays(this)
        findViewById<View>(R.id.rowPostNotif).visibility = if (postOk) View.GONE else View.VISIBLE
        findViewById<View>(R.id.rowNotifAccess).visibility = if (notifOk) View.GONE else View.VISIBLE
        findViewById<View>(R.id.rowBatteryOpt).visibility = if (batteryOk) View.GONE else View.VISIBLE
        findViewById<View>(R.id.rowDnd).visibility = if (dndOk) View.GONE else View.VISIBLE
        findViewById<View>(R.id.rowOverlay).visibility = if (overlayOk) View.GONE else View.VISIBLE
        findViewById<View>(R.id.setupSection).visibility =
            if (notifOk && batteryOk && postOk && dndOk && overlayOk) View.GONE else View.VISIBLE
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

    /**
     * "AndroMac 1.1.0 is available" — Install now, Later, or Skip this version.
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

    /** Do Not Disturb access: without it Android refuses to let the Mac silence the phone. */
    private fun hasDndAccess(): Boolean =
        getSystemService(NotificationManager::class.java).isNotificationPolicyAccessGranted

    private fun openDndAccess() {
        startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
    }

    private fun openOverlayAccess() {
        startActivity(
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
        )
    }

    private fun isIgnoringBatteryOptimizations(): Boolean =
        getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)

    @Suppress("BatteryLife")
    private fun requestIgnoreBatteryOptimizations() {
        startActivity(
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
        )
    }

    private companion object {
        const val REQ_POST_NOTIF = 1
        const val PERM_POST = "post"
        const val PERM_NOTIF_ACCESS = "listener"
    }
}
