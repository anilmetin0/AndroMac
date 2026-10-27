package dev.andromac.ui

import android.app.Activity
import android.os.Bundle
import android.widget.LinearLayout
import android.widget.Switch
import dev.andromac.R
import dev.andromac.core.Store
import dev.andromac.feature.SmsBridge

/**
 * Messages on the Mac: on/off, and the SMS and Contacts access it runs on. Turning it on asks for
 * both; a denial leaves the switch on and the rows below say what is still missing.
 */
class SmsSettingsActivity : Activity() {

    private lateinit var store: Store
    private val list by lazy { findViewById<LinearLayout>(R.id.smsPermissions) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_sms, R.string.sms_title)
        store = Store(this)

        bindSwitchRow(R.id.rowEnabled, R.id.swEnabled, store.sms) {
            if (it == store.sms) return@bindSwitchRow     // onResume re-reading it is no change
            store.sms = it
            SmsBridge.settingChanged()        // a live link starts or stops listening now
            if (it) grant(listOf(Permission.SMS, Permission.CONTACTS))
        }
        addPermissionRows(list, listOf(Permission.SMS, Permission.CONTACTS))
    }

    /** States are re-read on return: a grant or a revoke happens in a system dialog or Settings. */
    override fun onResume() {
        super.onResume()
        findViewById<Switch>(R.id.swEnabled).isChecked = store.sms
        renderPermissionRows(list)
        SmsBridge.settingChanged()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        onPermissionsResult(permissions, grantResults)
    }
}
