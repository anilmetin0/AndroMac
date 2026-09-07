package dev.andromac.net

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.andromac.core.Store

/**
 * Bring the link up again after the process is gone — only if we are already paired.
 *
 * Two moments, one job:
 *  - `BOOT_COMPLETED`, the obvious one.
 *  - `MY_PACKAGE_REPLACED`, the one that used to be missing. Installing a new APK force-stops the
 *    app, foreground service included, and nothing else in the app ever starts `LinkService` —
 *    `MainActivity.onCreate` and this receiver are the only callers. Without this action the phone
 *    stayed silent after every update until the user opened the app or rebooted, while the Mac sat
 *    in "Waiting for phone". The pairing itself survives an update (the identity key is
 *    Keystore-wrapped in the app's prefs), so there is nothing to redo: just start the service.
 *
 * Both actions are on the exemption list for starting a foreground service from the background,
 * and `connectedDevice` is not a while-in-use type, so the start is allowed.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> Unit
            else -> return
        }
        if (!Store(context).isPaired) return
        LinkService.start(context)
    }
}
