package dev.andromac.ui

import android.app.Activity
import android.content.Intent
import android.widget.ImageView
import android.widget.TextView
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.NetworkInfo

/**
 * The connection guide (view_onboarding.xml), on the main screen while unpaired and as the last
 * step of the setup flow. Every step shows its LIVE state: which step is stuck, rather than
 * "cannot connect".
 */
fun Activity.bindConnectionGuide() {
    bindNavRow(R.id.rowHelp) { startActivity(Intent(this, HelpActivity::class.java)) }
}

fun Activity.renderConnectionGuide() {
    val macSeen = Link.macSeenOnNetwork
    guideStep(R.id.step1Icon, R.id.step1Status, macSeen,
        getString(if (macSeen) R.string.onboarding_step1_found else R.string.onboarding_step1_missing))

    val ip = NetworkInfo.localIpv4()
    guideStep(R.id.step2Icon, R.id.step2Status, ip != null,
        if (ip != null) getString(R.string.onboarding_step2_ok, ip)
        else getString(R.string.onboarding_step2_none))

    val ready = macSeen && ip != null
    guideStep(R.id.step3Icon, R.id.step3Status, false,
        getString(if (ready) R.string.onboarding_step3_ready else R.string.onboarding_step3_waiting))
}

private fun Activity.guideStep(iconId: Int, statusId: Int, done: Boolean, status: String) {
    findViewById<ImageView>(iconId).setImageResource(
        if (done) R.drawable.ic_step_done else R.drawable.ic_step_pending
    )
    findViewById<TextView>(statusId).text = status
}
