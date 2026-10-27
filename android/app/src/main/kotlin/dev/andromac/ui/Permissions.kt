package dev.andromac.ui

import android.app.Activity
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import dev.andromac.R
import dev.andromac.core.Store
import dev.andromac.feature.NotificationRelay
import dev.andromac.net.LinkService

/**
 * Every permission the app can ask for, in the order they should be granted.
 *
 * One list feeds every surface: the card on the main screen (required ones only), the setup flow
 * and the Permissions screen. A check written three times drifted three ways before this.
 *
 * [runtime] names the permission when Android has a dialog for it; [grant] asks with that dialog
 * and falls back to [settingsIntent] once Android stops showing it. [minSdk] is where the
 * permission starts to exist: below it the entry is left out and counts as granted. The names are
 * strings rather than the `Manifest.permission` fields, which only exist from that same API level.
 */
enum class Permission(
    val titleRes: Int,
    val noteRes: Int,
    val kind: Kind,
    val runtime: String? = null,
    private val minSdk: Int = 0,
) {

    /** Android 17+: without it the phone cannot find or reach the Mac at all. */
    LOCAL_NETWORK(
        R.string.setup_local_network_title, R.string.setup_local_network_note, Kind.REQUIRED,
        "android.permission.ACCESS_LOCAL_NETWORK", 37,
    ) {
        /** After a denial only the app's page can grant it. */
        override fun settingsIntent(ctx: Context): Intent = appDetails(ctx)
    },

    POST_NOTIFICATIONS(
        R.string.setup_post_notif_title, R.string.setup_post_notif_note, Kind.REQUIRED,
        "android.permission.POST_NOTIFICATIONS", 33,
    ) {
        override fun settingsIntent(ctx: Context): Intent =
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName)
    },

    NOTIFICATION_ACCESS(R.string.setup_notif_title, R.string.setup_notif_note, Kind.REQUIRED) {
        /**
         * A substring match is NOT enough: the release package is `dev.andromac` and the debug
         * package is `dev.andromac.debug`. With only the debug variant enabled, release used to
         * report the access as "granted".
         */
        override fun granted(ctx: Context): Boolean =
            ctx.getSystemService(NotificationManager::class.java)
                .isNotificationListenerAccessGranted(ComponentName(ctx, NotificationRelay::class.java))

        override fun settingsIntent(ctx: Context): Intent =
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
    },

    BATTERY(R.string.setup_battery_title, R.string.setup_battery_note, Kind.RECOMMENDED) {
        override fun granted(ctx: Context): Boolean =
            ctx.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(ctx.packageName)

        @Suppress("BatteryLife")
        override fun settingsIntent(ctx: Context): Intent =
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}"))
    },

    /**
     * "Nearby devices" on Android 12+: the Mac asks the phone to bond over Bluetooth so it can act
     * as a hands-free device for calls (feature/BluetoothPair.kt).
     */
    BLUETOOTH_CONNECT(
        R.string.setup_bt_title, R.string.setup_bt_note, Kind.OPTIONAL,
        "android.permission.BLUETOOTH_CONNECT", 31,
    ) {
        override fun settingsIntent(ctx: Context): Intent = appDetails(ctx)
    },

    DND(R.string.setup_dnd_title, R.string.setup_dnd_note, Kind.OPTIONAL) {
        /** Without it Android refuses to let the Mac silence the phone. */
        override fun granted(ctx: Context): Boolean =
            ctx.getSystemService(NotificationManager::class.java).isNotificationPolicyAccessGranted

        override fun settingsIntent(ctx: Context): Intent =
            Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
    },

    OVERLAY(R.string.setup_overlay_title, R.string.setup_overlay_note, Kind.OPTIONAL) {
        /**
         * Needs SYSTEM_ALERT_WINDOW in the manifest. Without that line the app is missing from
         * Android's "Display over other apps" list and this always returns false.
         */
        override fun granted(ctx: Context): Boolean = Settings.canDrawOverlays(ctx)

        override fun settingsIntent(ctx: Context): Intent =
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${ctx.packageName}"))
    };

    /** Whether this Android version has the permission at all. */
    val applies: Boolean get() = Build.VERSION.SDK_INT >= minSdk

    /** A runtime permission is granted when Android says so; the others override this. */
    open fun granted(ctx: Context): Boolean =
        !applies || runtime == null || ctx.checkSelfPermission(runtime) == PackageManager.PERMISSION_GRANTED

    abstract fun settingsIntent(ctx: Context): Intent

    /** Required: a mirror that mirrors nothing without it. Recommended: it works, but drops. */
    enum class Kind(val labelRes: Int) {
        REQUIRED(R.string.permission_required),
        RECOMMENDED(R.string.permission_recommended),
        OPTIONAL(R.string.permission_optional),
    }

    companion object {
        /** Every permission this Android version has, in order. */
        fun current(kind: Kind? = null): List<Permission> =
            entries.filter { it.applies && (kind == null || it.kind == kind) }

        fun missing(ctx: Context): List<Permission> = current().filter { !it.granted(ctx) }
        fun missingRequired(ctx: Context): List<Permission> = missing(ctx).filter { it.kind == Kind.REQUIRED }

        /** "All granted" or "2 not granted", for the row summaries. */
        fun summary(ctx: Context): String {
            val n = missing(ctx).size
            return if (n == 0) ctx.getString(R.string.permissions_all_granted)
            else ctx.resources.getQuantityString(R.plurals.permissions_missing, n, n)
        }

        fun appDetails(ctx: Context): Intent =
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}"))

        const val REQ_GRANT = 7
    }
}

/**
 * Ask for [permission] the way Android allows: its runtime dialog while Android still shows one,
 * else the settings screen that grants it. Android does not say whether the dialog would appear,
 * so the app remembers what it asked for: asked before and no rationale means the user denied it
 * for good, and only Settings can change that now.
 */
fun Activity.grant(permission: Permission) {
    val runtime = permission.runtime
    val store = Store(this)
    if (runtime != null && (runtime !in store.permissionsAsked || shouldShowRequestPermissionRationale(runtime))) {
        store.permissionsAsked += runtime
        requestPermissions(arrayOf(runtime), Permission.REQ_GRANT)
        return
    }
    // Some builds drop one of these screens (the battery exemption most often); the app's own page is always there.
    runCatching { startActivity(permission.settingsIntent(this)) }
        .onFailure { startActivity(Permission.appDetails(this)) }
}

/**
 * The link thread dialled while the dialog was up, failed, and is waiting out its backoff. With
 * local network access in place, the next attempt should not wait for that.
 */
fun Activity.onPermissionsResult(permissions: Array<out String>, grantResults: IntArray) {
    val local = permissions.indexOf(Permission.LOCAL_NETWORK.runtime)
    if (local >= 0 && grantResults.getOrNull(local) == PackageManager.PERMISSION_GRANTED) LinkService.start(this)
}

/**
 * One row per permission from item_permission.xml: Allow while it is missing, a check once it is
 * granted. A tap on a granted row opens its settings screen, where it can be revoked.
 */
fun Activity.addPermissionRows(list: LinearLayout, permissions: List<Permission>) {
    list.removeAllViews()
    for (permission in permissions) {
        val row = layoutInflater.inflate(R.layout.item_permission, list, false)
        row.tag = permission
        row.findViewById<TextView>(R.id.permTitle).setText(permission.titleRes)
        row.findViewById<TextView>(R.id.permNote).setText(permission.noteRes)
        row.findViewById<View>(R.id.permAllow).setOnClickListener { grant(permission) }
        row.setOnClickListener {
            if (!permission.granted(this)) grant(permission)
            else runCatching { startActivity(permission.settingsIntent(this)) }
        }
        list.addView(row)
    }
    renderPermissionRows(list)
}

fun Activity.renderPermissionRows(list: LinearLayout) {
    for (i in 0 until list.childCount) {
        val row = list.getChildAt(i)
        val granted = (row.tag as Permission).granted(this)
        row.findViewById<View>(R.id.permAllow).visibility = if (granted) View.GONE else View.VISIBLE
        row.findViewById<View>(R.id.permGranted).visibility = if (granted) View.VISIBLE else View.GONE
    }
}
