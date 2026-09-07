package dev.andromac.ui

import android.app.Activity
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import dev.andromac.R

/**
 * Every permission with its live state, granted or not. The main screen shows only what is
 * missing; this screen is the full list, so a user can see what was granted and where to
 * revoke it. Tapping a row opens the matching system screen.
 */
class PermissionsActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_permissions, R.string.permissions_title)
        val list = findViewById<LinearLayout>(R.id.permissionList)
        val inflater = LayoutInflater.from(this)
        for (permission in Permission.entries) {
            val row = inflater.inflate(R.layout.item_permission, list, false)
            row.tag = permission
            row.findViewById<TextView>(R.id.permTitle).setText(permission.titleRes)
            row.findViewById<TextView>(R.id.permNote).setText(permission.noteRes)
            row.setOnClickListener { startActivity(permission.settingsIntent(this)) }
            list.addView(row)
        }
    }

    override fun onResume() {
        super.onResume()
        val list = findViewById<LinearLayout>(R.id.permissionList)
        for (i in 0 until list.childCount) render(list.getChildAt(i))
        findViewById<TextView>(R.id.permissionsSummary).text = Permission.summary(this)
    }

    private fun render(row: View) {
        val permission = row.tag as Permission
        val granted = permission.granted(this)
        row.findViewById<TextView>(R.id.permState).apply {
            setText(if (granted) R.string.permission_granted else R.string.permission_not_granted)
            setTextColor(getColor(if (granted) R.color.am_state_ok else R.color.am_state_pending))
        }
        row.findViewById<TextView>(R.id.permKind).setText(permission.kind.labelRes)
    }
}
