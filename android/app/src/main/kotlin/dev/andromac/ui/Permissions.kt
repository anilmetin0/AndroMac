package dev.andromac.ui

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import dev.andromac.R
import dev.andromac.feature.NotificationRelay

/**
 * Every permission the app can ask for, in the order they should be granted.
 *
 * One list feeds three surfaces: the banner (required ones only), the card on the main screen,
 * and the Permissions screen. A check written three times drifted three ways before this.
 */
enum class Permission(val titleRes: Int, val noteRes: Int, val kind: Kind) {

    POST_NOTIFICATIONS(R.string.setup_post_notif_title, R.string.setup_post_notif_note, Kind.REQUIRED) {
        /** Before API 33 there is no such permission; there it always counts as granted. */
        override fun granted(ctx: Context): Boolean =
            Build.VERSION.SDK_INT < 33 ||
                ctx.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

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

    abstract fun granted(ctx: Context): Boolean
    abstract fun settingsIntent(ctx: Context): Intent

    /** Required: a mirror that mirrors nothing without it. Recommended: it works, but drops. */
    enum class Kind(val labelRes: Int) {
        REQUIRED(R.string.permission_required),
        RECOMMENDED(R.string.permission_recommended),
        OPTIONAL(R.string.permission_optional),
    }

    companion object {
        fun missing(ctx: Context): List<Permission> = entries.filter { !it.granted(ctx) }
        fun missingRequired(ctx: Context): List<Permission> = missing(ctx).filter { it.kind == Kind.REQUIRED }

        /** "All granted" or "2 not granted", for the row summaries. */
        fun summary(ctx: Context): String {
            val n = missing(ctx).size
            return if (n == 0) ctx.getString(R.string.permissions_all_granted)
            else ctx.resources.getQuantityString(R.plurals.permissions_missing, n, n)
        }
    }
}
