package dev.andromac.ui

import android.Manifest
import android.app.Activity
import android.os.Bundle
import dev.andromac.feature.BluetoothPair

/**
 * Invisible: opened by the user's tap on the pairing notification, which is the confirmation that
 * starts the bond. Asks for "Nearby devices" (BLUETOOTH_CONNECT) first when needed, which a
 * service cannot do. Not exported: only our own immutable PendingIntent reaches it.
 */
class BluetoothPairActivity : Activity() {

    private val address: String get() = intent?.getStringExtra(EXTRA_ADDRESS).orEmpty()

    @Suppress("DEPRECATION")        // overridePendingTransition: the replacement is above minSdk
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
        if (address.isEmpty()) { finish(); return }
        if (BluetoothPair.granted(this)) {
            BluetoothPair.bond(this, address)
            finish()
        } else if (savedInstanceState == null) {
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), REQ_CONNECT)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // Denied: bond() reports the failure to the Mac instead of leaving it waiting.
        BluetoothPair.bond(this, address)
        finish()
    }

    companion object {
        const val EXTRA_ADDRESS = "address"
        private const val REQ_CONNECT = 2
    }
}
