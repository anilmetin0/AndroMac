package dev.andromac.ui

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.os.Build
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Store
import dev.andromac.feature.ClipHistory
import dev.andromac.feature.ClipboardBridge

/**
 * The recent clipboard entries in both directions, from the in-memory [ClipHistory].
 * Tap copies an entry back to this phone; the send button (or a long press) sends it to the Mac.
 * Refreshes only when an entry arrives or leaves: no timer, the relative times are as of opening.
 */
class ClipboardHistoryActivity : Activity() {

    private lateinit var bridge: ClipboardBridge
    private val changed: () -> Unit = { runOnUiThread { render() } }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_clip_history, R.string.history_title)
        bridge = ClipboardBridge(this, Store(this))
        findViewById<ImageButton>(R.id.headerAction).apply {
            setImageResource(R.drawable.ic_delete)
            contentDescription = getString(R.string.history_clear)
            setOnClickListener { ClipHistory.clear() }
        }
    }

    override fun onStart() {
        super.onStart()
        ClipHistory.addListener(changed)
        render()
    }

    override fun onStop() {
        ClipHistory.removeListener(changed)
        super.onStop()
    }

    private fun render() {
        val entries = ClipHistory.list()
        val list = findViewById<LinearLayout>(R.id.historyList)
        list.removeAllViews()
        list.visibility = if (entries.isEmpty()) View.GONE else View.VISIBLE
        findViewById<View>(R.id.historyEmpty).visibility = if (entries.isEmpty()) View.VISIBLE else View.GONE
        findViewById<View>(R.id.historyNote).visibility = if (entries.isEmpty()) View.GONE else View.VISIBLE
        findViewById<View>(R.id.headerAction).visibility = if (entries.isEmpty()) View.GONE else View.VISIBLE

        val inflater = LayoutInflater.from(this)
        val now = System.currentTimeMillis()
        for (entry in entries) {
            val row = inflater.inflate(R.layout.item_clip, list, false)
            row.findViewById<ImageView>(R.id.clipDirection).setImageResource(
                if (entry.fromMac) R.drawable.ic_arrow_down else R.drawable.ic_arrow_up
            )
            row.findViewById<TextView>(R.id.clipText).text = entry.text
            val ago = ago(entry.time, now)
            row.findViewById<TextView>(R.id.clipMeta).text =
                getString(if (entry.fromMac) R.string.history_from_mac else R.string.history_to_mac, ago)
            row.setOnClickListener { copy(entry.text) }
            row.setOnLongClickListener { send(entry.text); true }
            row.findViewById<View>(R.id.clipSend).setOnClickListener { send(entry.text) }
            list.addView(row)
        }
    }

    private fun copy(text: String) {
        // Marked as the Mac's, so returning to the app does not send it straight back.
        ClipboardBridge.lastFromMac = text
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("AndroMac", text))
        // Android 13+ confirms a copy itself; a toast on top would say it twice.
        if (Build.VERSION.SDK_INT < 33) Toast.makeText(this, R.string.clip_pasted, Toast.LENGTH_SHORT).show()
    }

    private fun send(text: String) {
        val sent = Link.isConnected && bridge.sendText(text)
        Toast.makeText(this, if (sent) R.string.clip_sent else R.string.clip_offline, Toast.LENGTH_SHORT).show()
    }
}
