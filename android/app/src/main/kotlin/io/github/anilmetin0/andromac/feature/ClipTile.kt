package io.github.anilmetin0.andromac.feature

import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import io.github.anilmetin0.andromac.core.Link
import io.github.anilmetin0.andromac.R
import io.github.anilmetin0.andromac.ui.ClipHelperActivity

/**
 * Quick Settings tile: "Send clipboard to Mac".
 *
 * The tile cannot read the clipboard itself (see [ClipboardBridge] — the API 29+ focus
 * restriction), so it opens a transparent activity that takes focus. For the user it is
 * still a single tap.
 */
class ClipTile : TileService() {

    override fun onStartListening() {
        qsTile?.apply {
            state = if (Link.isConnected) Tile.STATE_ACTIVE else Tile.STATE_UNAVAILABLE
            subtitle = getString(if (Link.isConnected) R.string.tile_sub_ready else R.string.state_offline)
            updateTile()
        }
    }

    override fun onClick() {
        val intent = ClipHelperActivity.getIntent(this)
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                android.app.PendingIntent.getActivity(
                    this, 3, intent,
                    android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
                )
            )
        } else {
            // Below 34 the PendingIntent overload does not exist; the Intent one is gated here.
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }
}
