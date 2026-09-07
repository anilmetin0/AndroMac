package dev.andromac.ui

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import dev.andromac.R
import dev.andromac.core.Store
import dev.andromac.feature.ClipboardBridge

// The share-sheet target used to live here as ClipActivity; it is now ShareActivity, which
// handles both text (→ clipboard) and files (→ FileTransfer). The clipboard read/write modes
// stay in ClipHelperActivity with exported=false: an exported activity can be invoked by an
// explicit intent, so any installed app could make it ship the clipboard to the Mac or overwrite it.

/**
 * An invisible helper activity that takes focus.
 *
 * Android 10+ exposes the clipboard only to the focused app. The service and the QS tile are
 * never focused, so reads and writes go through here: the work happens the moment window
 * focus arrives and the activity finishes. The user sees nothing (transparent theme, no
 * animation).
 *
 *  - MODE_GET : read the clipboard and send it to the Mac (QS tile, ongoing notification,
 *               clipboard settings)
 *  - MODE_PUT : write the given text into the clipboard  (the "Paste" notification action)
 */
class ClipHelperActivity : Activity() {

    private lateinit var bridge: ClipboardBridge
    private var done = false

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
        bridge = ClipboardBridge(this, Store(this))
    }

    /**
     * singleTask: a second tap does not spawn a new instance. Without this the live instance
     * would reuse the stale intent with `done=true` and do nothing at all.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        done = false
        if (hasWindowFocus()) act()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) act()
    }

    private fun act() {
        if (done) return
        when (intent?.getStringExtra(EXTRA_MODE)) {
            MODE_GET -> {
                done = true
                finishQuietly(bridge.sendCurrentClip(), R.string.clip_sent_from_clipboard)
            }
            MODE_PUT -> {
                done = true
                val text = intent.getStringExtra(EXTRA_TEXT).orEmpty()
                val ok = runCatching {
                    getSystemService(ClipboardManager::class.java)
                        .setPrimaryClip(ClipData.newPlainText("AndroMac", text))
                }.isSuccess
                ClipboardBridge.lastFromMac = text
                finishQuietly(ok, R.string.clip_pasted)
            }
            else -> finish()
        }
    }

    companion object {
        private fun base(ctx: Context) = Intent(ctx, ClipHelperActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)

        fun getIntent(ctx: Context): Intent = base(ctx).putExtra(EXTRA_MODE, MODE_GET)

        fun putIntent(ctx: Context, text: String): Intent =
            base(ctx).putExtra(EXTRA_MODE, MODE_PUT).putExtra(EXTRA_TEXT, text)
    }
}

private const val EXTRA_MODE = "mode"
private const val EXTRA_TEXT = "text"
private const val MODE_GET = "get"
private const val MODE_PUT = "put"

@Suppress("DEPRECATION")
private fun Activity.finishQuietly(ok: Boolean, okMessage: Int) {
    Toast.makeText(
        this, if (ok) getString(okMessage) else getString(R.string.clip_offline),
        Toast.LENGTH_SHORT,
    ).show()
    finish()
    overridePendingTransition(0, 0)
}
