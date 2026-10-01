package dev.andromac.feature

import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Store
import dev.andromac.net.LinkService

/**
 * Quick Settings tile: the connection on and off. It flips the same auto-connect switch as the
 * Connection screen, so "off" stays off until the tile, the notification or the app turns it back.
 */
class ConnectionTile : TileService() {

    override fun onStartListening() {
        val store = Store(this)
        qsTile?.apply {
            state = when {
                !store.isPaired -> Tile.STATE_UNAVAILABLE
                store.autoConnect -> Tile.STATE_ACTIVE
                else -> Tile.STATE_INACTIVE
            }
            subtitle = getString(
                when {
                    !store.isPaired -> R.string.state_unpaired
                    Link.isConnected -> R.string.state_connected
                    store.autoConnect -> R.string.state_waiting_mac
                    else -> R.string.state_auto_off
                }
            )
            updateTile()
        }
    }

    override fun onClick() {
        val store = Store(this)
        if (!store.isPaired) return
        val off = store.autoConnect
        store.autoConnect = !off             // written here too, so the redraw below sees it
        LinkService.start(this, if (off) LinkService.ACTION_DISCONNECT else LinkService.ACTION_RESUME)
        onStartListening()
    }
}
