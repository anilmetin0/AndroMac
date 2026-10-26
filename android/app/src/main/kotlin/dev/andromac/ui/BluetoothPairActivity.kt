package dev.andromac.ui

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Bundle
import dev.andromac.feature.BluetoothPair

/**
 * Invisible: asks for "Nearby devices" (BLUETOOTH_CONNECT), which a service cannot do, then hands
 * the pairing the Mac asked for back to [BluetoothPair]. Opened only from our own notification.
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
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) BluetoothPair.bond(this, address)
        finish()
    }

    companion object {
        const val EXTRA_ADDRESS = "address"
        private const val REQ_CONNECT = 2
    }
}
