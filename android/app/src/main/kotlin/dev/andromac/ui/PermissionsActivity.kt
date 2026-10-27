package dev.andromac.ui

import android.app.Activity
import android.os.Bundle
import android.widget.LinearLayout
import dev.andromac.R

/**
 * Every permission with its live state, grouped as Required, Recommended and Optional. The main
 * screen shows only the required ones that are missing; this screen is the full list, so a user
 * can see what was granted and where to revoke it.
 */
class PermissionsActivity : Activity() {

    private val lists by lazy {
        mapOf(
            Permission.Kind.REQUIRED to findViewById<LinearLayout>(R.id.permsRequired),
            Permission.Kind.RECOMMENDED to findViewById(R.id.permsRecommended),
            Permission.Kind.OPTIONAL to findViewById(R.id.permsOptional),
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_permissions, R.string.permissions_title)
        for ((kind, list) in lists) addPermissionRows(list, Permission.current(kind))
    }

    /** States are re-read on return: the grant happens in Settings or a system dialog. */
    override fun onResume() {
        super.onResume()
        lists.values.forEach(::renderPermissionRows)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        onPermissionsResult(permissions, grantResults)
    }
}
