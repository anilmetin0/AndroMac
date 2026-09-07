package dev.andromac.ui

import android.app.Activity
import android.os.Bundle
import android.widget.TextView
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.NetworkInfo
import dev.andromac.core.Store

/**
 * Connection help.
 *
 * The top of the screen carries LIVE diagnostics: instead of telling the user "cannot
 * connect" we show which condition is not met. The sections below it are static prose.
 */
class HelpActivity : Activity() {

    private lateinit var store: Store

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_help, R.string.help_title)
        store = Store(this)
    }

    override fun onResume() {
        super.onResume()
        findViewById<TextView>(R.id.diagnostics).text = diagnostics()
    }

    private fun diagnostics(): String {
        val ip = NetworkInfo.localIpv4()
        val subnet = NetworkInfo.subnetOf(ip)
        val none = getString(R.string.diag_none)
        return buildString {
            appendLine(line(R.string.diag_ip, ip ?: getString(R.string.diag_no_network)))
            if (subnet != null) appendLine(line(R.string.diag_subnet, "$subnet.*"))
            appendLine(line(R.string.diag_mac_seen, yesNo(Link.macSeenOnNetwork)))
            appendLine(line(R.string.diag_pairing, if (store.isPaired) store.pairedName else none))
            appendLine(
                line(R.string.diag_link, if (Link.isConnected) getString(R.string.diag_up) else none)
            )
            append(line(R.string.diag_version, versionLabel()))
        }
    }

    /** Alignment is done in code: the column holds even when a translation changes the label length. */
    private fun line(labelId: Int, value: String) =
        "${getString(labelId).padEnd(LABEL_WIDTH)}: $value"

    private fun yesNo(value: Boolean) =
        getString(if (value) R.string.diag_yes else R.string.diag_no)

    private companion object {
        const val LABEL_WIDTH = 11
    }
}
