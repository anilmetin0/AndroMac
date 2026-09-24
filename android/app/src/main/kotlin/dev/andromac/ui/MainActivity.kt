package dev.andromac.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.NetworkInfo
import dev.andromac.core.Store
import dev.andromac.feature.ClipHistory
import dev.andromac.feature.ClipboardBridge
import dev.andromac.feature.FindPhone
import dev.andromac.feature.MediaBridge
import dev.andromac.feature.UpdateCheck
import dev.andromac.feature.Updater
import dev.andromac.net.LinkService

/**
 * The home screen.
 *
 * Design rule: the screen shows state, not prose. Status on top (with the Mac's name), the
 * required permissions only while one is missing, the connection guide only while unpaired, the
 * four sync switches and the clipboard. Everything else is behind the Settings icon; the guide
 * and diagnostics stay behind the info icon once paired.
 */
class MainActivity : Activity() {

    private lateinit var store: Store
    private lateinit var status: TextView
    private lateinit var detail: TextView
    private lateinit var statusDot: View
    private lateinit var pairButton: Button

    private val listener: (Link.State) -> Unit = { state -> runOnUiThread { render(state) } }
    private val historyChanged: () -> Unit = { runOnUiThread { renderClipboard() } }
    /** The update card follows the install's progress; Updater calls this on the main thread. */
    private val installChanged: (UpdateCheck.Step) -> Unit = { renderUpdate() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        findViewById<View>(R.id.scrollRoot).padForSystemBars()
        store = Store(this)

        findViewById<View>(R.id.actionHelp).setOnClickListener { open(HelpActivity::class.java) }
        findViewById<View>(R.id.actionSettings).setOnClickListener { open(SettingsActivity::class.java) }

        status = findViewById(R.id.status)
        detail = findViewById(R.id.detail)
        statusDot = findViewById(R.id.statusDot)
        pairButton = findViewById(R.id.pair)
        pairButton.setOnClickListener { onPairTapped() }
        // Once paired the card opens the Mac's details: name, address, reconnect, forget.
        bindNavRow(R.id.statusCard) { if (store.isPaired) open(ConnectionActivity::class.java) }

        for ((permission, rowId) in permissionRows) {
            bindNavRow(rowId) { startActivity(permission.settingsIntent(this)) }
        }
        findViewById<View>(R.id.permissionDismiss).setOnClickListener {
            // Dismissal is remembered against what is missing right now, so the card stays gone
            // for this problem and comes back if a different permission is revoked later.
            store.permissionsDismissed = Permission.missingRequired(this).joinToString(",") { it.name }
            renderPermissions()
        }

        bindNavRow(R.id.rowHelp) { open(HelpActivity::class.java) }
        bindNavRow(R.id.updateCard) { open(UpdateSettingsActivity::class.java) }
        bindNavRow(R.id.rowClipHistory) { open(ClipboardHistoryActivity::class.java) }
        bindNavRow(R.id.rowSendClip) { sendClipboard() }

        bindSwitchRow(R.id.rowBattery, R.id.swBattery, store.syncBattery) { store.syncBattery = it }
        bindSwitchRow(R.id.rowClipboard, R.id.swClipboard, store.syncClipboard) { store.syncClipboard = it }
        bindSwitchRow(R.id.rowNotifications, R.id.swNotifications, store.syncNotifications) {
            store.syncNotifications = it
        }
        bindSwitchRow(R.id.rowMedia, R.id.swMedia, store.syncMedia) {
            store.syncMedia = it
            MediaBridge.settingChanged()      // apply immediately if connected, do not wait for a reconnect
        }

        // Ask for what can be asked for. Notification access has no runtime dialog, it is a
        // settings screen, so it is offered once, right after this, in [offerNotificationAccess].
        val ask = buildList {
            if (Build.VERSION.SDK_INT >= 37 && !Permission.LOCAL_NETWORK.granted(this@MainActivity)) {
                add(android.Manifest.permission.ACCESS_LOCAL_NETWORK)
            }
            if (Build.VERSION.SDK_INT >= 33 && !Permission.POST_NOTIFICATIONS.granted(this@MainActivity)) {
                add(android.Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (ask.isNotEmpty()) requestPermissions(ask.toTypedArray(), REQ_POST_NOTIF)
        LinkService.start(this)
    }

    override fun onStart() {
        super.onStart()
        Link.addListener(listener)
        ClipHistory.addListener(historyChanged)
        Updater.addListener(installChanged)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        render(Link.state)
        // The link thread dialled while the dialog was up, failed, and is waiting out its
        // backoff. With the permission in place, the next attempt should not wait for that.
        // The string, not the API 37 field: an inlined constant, harmless below 37 (never asked there).
        val local = permissions.indexOf("android.permission.ACCESS_LOCAL_NETWORK")
        if (local >= 0 && grantResults.getOrNull(local) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            LinkService.start(this)
        }
        if (requestCode == REQ_POST_NOTIF) offerNotificationAccess()
    }

    override fun onResume() {
        super.onResume()
        FindPhone.stop(this)        // opening the app means they found the phone
        render(Link.state)          // permissions may have changed while away in Settings
        offerNotificationAccess()
        // At most daily, and only when the app is opened: the phone never polls (ENERGY rule 1).
        // A check that starts now offers when it is done; the stored result may be stale.
        val checking = runUpdateCheckIfDue(store) {
            if (isFinishing) return@runUpdateCheckIfDue
            renderUpdate()
            offerUpdate()
        }
        if (!checking) offerUpdate()
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
        ClipHistory.removeListener(historyChanged)
        Updater.removeListener(installChanged)
        // On rotation the dialog stayed attached to the old activity and leaked its window.
        pairingDialog?.dismiss()
        pairingDialog = null
        chooserDialog?.dismiss()
        chooserDialog = null
        keyDialog?.dismiss()
        keyDialog = null
        // A rotation takes the unanswered offer along to the new screen; anything else counts as Later.
        if (updateDialog?.isShowing == true && isChangingConfigurations) updateOffered = false
        updateDialog?.dismiss()
        updateDialog = null
        super.onStop()
    }

    // ---------------------------------------------------------------- rendering

    private fun render(state: Link.State) {
        val paired = store.isPaired
        // The Mac's name as soon as it is known: the saved one, or the one met while pairing.
        val mac = store.pairedName
        val dotColor = when (state) {
            is Link.State.Connected -> R.color.am_state_ok
            is Link.State.Searching, is Link.State.NeedsPairing -> R.color.am_state_pending
            is Link.State.KeyChanged -> R.color.am_state_alert
            Link.State.Stopped -> R.color.am_state_idle
        }
        status.text = when (state) {
            is Link.State.Connected -> getString(R.string.state_connected_to, state.peerName)
            is Link.State.Searching -> when {
                !paired -> getString(R.string.state_searching)
                mac.isNotEmpty() -> getString(R.string.state_connecting_to, mac)
                else -> getString(R.string.state_waiting_mac)
            }
            is Link.State.NeedsPairing -> getString(R.string.state_waiting_approval)
            is Link.State.KeyChanged -> getString(R.string.state_key_changed)
            Link.State.Stopped -> getString(when {
                !paired -> R.string.state_unpaired
                !store.autoConnect -> R.string.state_auto_off
                else -> R.string.state_offline
            })
        }
        statusDot.background?.mutate()?.setTint(getColor(dotColor))

        detail.text = when (state) {
            is Link.State.Connected -> ""
            is Link.State.NeedsPairing -> getString(R.string.pair_code_with, state.peerName, state.sas.chunked(3).joinToString(" "))
            is Link.State.KeyChanged -> getString(R.string.key_changed_tap)
            // While pairing, every Mac the browse saw, so it is clear which one answers.
            is Link.State.Searching -> when {
                NetworkInfo.localIpv4() == null -> getString(R.string.onboarding_step2_none)
                !paired && Link.discoveredMacs.isNotEmpty() ->
                    getString(R.string.macs_found, Link.discoveredMacs.keys.joinToString(", "))
                else -> ""
            }
            // Unpaired: the Macs the last browse saw, never a prompt for one of them.
            Link.State.Stopped -> when {
                paired -> mac
                Link.discoveredMacs.isNotEmpty() ->
                    getString(R.string.macs_found, Link.discoveredMacs.keys.joinToString(", "))
                else -> ""
            }
        }
        detail.visibility = if (detail.text.isEmpty()) View.GONE else View.VISIBLE

        // The primary action only when there is something to do.
        pairButton.visibility = when (state) {
            is Link.State.Connected -> View.GONE
            is Link.State.Searching -> if (paired) View.GONE else View.VISIBLE
            Link.State.Stopped -> if (paired && store.autoConnect) View.GONE else View.VISIBLE
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
        findViewById<View>(R.id.statusCard).isClickable = paired

        renderOnboarding()
        renderPermissions()
        renderUpdate()
        renderClipboard()

        if (state is Link.State.NeedsPairing) confirmPairing(state.peerName, state.sas, state.peerKey)
        // The Pair tap browsed and found several Macs: let the user pick one.
        if (state !is Link.State.Searching && state != Link.State.Stopped) awaitingChoice = false
        if (awaitingChoice && !paired && state == Link.State.Stopped && Link.discoveredMacs.size > 1) {
            awaitingChoice = false
            chooseMac()
        }
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
        Permission.LOCAL_NETWORK to R.id.rowLocalNetwork,
        Permission.POST_NOTIFICATIONS to R.id.rowPostNotif,
        Permission.NOTIFICATION_ACCESS to R.id.rowNotifAccess,
    )

    /**
     * The permission card: only while a REQUIRED permission is missing, one row per missing one,
     * tappable to grant it and dismissible with the cross. A mirror that relays nothing is the one
     * state worth interrupting for; the full list lives in Settings, Permissions.
     */
    private fun renderPermissions() {
        val missing = Permission.missingRequired(this)
        val show = missing.isNotEmpty() && store.permissionsDismissed != missing.joinToString(",") { it.name }
        findViewById<View>(R.id.permissionCard).visibility = if (show) View.VISIBLE else View.GONE
        for ((permission, rowId) in permissionRows) {
            findViewById<View>(rowId).visibility = if (permission in missing) View.VISIBLE else View.GONE
        }
    }

    /** The latest clipboard entry as a one-line preview; the send row only while connected. */
    private fun renderClipboard() {
        findViewById<TextView>(R.id.clipHistoryPreview).text =
            ClipHistory.list().firstOrNull()?.text?.lineSequence()?.first()
                ?: getString(R.string.history_empty)
        findViewById<View>(R.id.rowSendClip).visibility = if (Link.isConnected) View.VISIBLE else View.GONE
    }

    /** The app has focus right now, so the clipboard can be read here without the helper activity. */
    private fun sendClipboard() {
        val message = when {
            !Link.isConnected -> R.string.clip_offline
            ClipboardBridge(this, store).sendCurrentClip() -> R.string.clip_sent_from_clipboard
            else -> R.string.clip_nothing_to_send
        }
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun open(screen: Class<out Activity>) = startActivity(Intent(this, screen))

    /** The update card. It reads the stored result, no request here. */
    private fun renderUpdate() {
        val newer = newerRelease(store)
        findViewById<View>(R.id.updateCard).visibility = if (newer == null) View.GONE else View.VISIBLE
        if (newer != null) {
            findViewById<TextView>(R.id.updateBody).text = updateCardBody(newer)
        }
    }

    /**
     * The notes with Install now, Later and Skip this version, or a silent install once the user
     * leaves the app when allowed. Once per process and once per release: Later holds until the
     * app is next started, a skipped release never comes back, and the Updates screen still has
     * the button for whoever changes their mind.
     */
    private fun offerUpdate() {
        if (updateOffered || isFinishing) return
        updateOffered = offerOrInstallUpdate(store) { updateDialog = it }
    }

    private var updateDialog: AlertDialog? = null

    // ---------------------------------------------------------------- pairing

    private var pairingDialog: AlertDialog? = null
    private var chooserDialog: AlertDialog? = null
    private var keyDialog: AlertDialog? = null
    /** Pair was tapped with fewer than two Macs known; the browse may still turn up more. */
    private var awaitingChoice = false

    private fun onPairTapped() {
        when (val s = Link.state) {
            is Link.State.NeedsPairing -> confirmPairing(s.peerName, s.sas, s.peerKey)
            is Link.State.KeyChanged -> warnKeyChange(s.peerName, s.sas)
            else -> when {
                store.isPaired -> LinkService.start(this, LinkService.ACTION_CONNECT)
                Link.discoveredMacs.size > 1 -> chooseMac()
                else -> {
                    awaitingChoice = true
                    LinkService.start(this, LinkService.ACTION_PAIR)
                }
            }
        }
    }

    /**
     * Several Macs on this network: the chosen one is the only one dialled for pairing. The last
     * item browses again, for a Mac that was missing or has gone.
     */
    private fun chooseMac() {
        if (chooserDialog?.isShowing == true) return
        val macs = Link.discoveredMacs.keys.toList()
        chooserDialog = AlertDialog.Builder(this)
            .setTitle(R.string.pair_choose_title)
            .setItems((macs + getString(R.string.pair_search_again)).toTypedArray()) { _, i ->
                if (i < macs.size) LinkService.start(this, LinkService.ACTION_PAIR, macs[i])
                else {
                    awaitingChoice = true
                    LinkService.start(this, LinkService.ACTION_PAIR)
                }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
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
        if (keyDialog?.isShowing == true) return
        keyDialog = AlertDialog.Builder(this)
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
        // Several Macs on this network: name the others, so it is clear which one this is. The
        // peer is named by its advertised `n`, the list by service name: either may match.
        val others = Link.discoveredMacs.filter { (service, name) -> service != peerName && name != peerName }.keys
        findViewById<TextView>(R.id.pairOthers).apply {
            text = getString(R.string.pairing_others, others.joinToString(", "))
            visibility = if (others.isEmpty()) View.GONE else View.VISIBLE
        }
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
        /** The launch offer was made (or an automatic install started) in this process. */
        var updateOffered = false
    }
}
