package dev.andromac.ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Store
import dev.andromac.feature.ClipboardBridge
import dev.andromac.feature.FileTransfer

/**
 * The share-sheet target ("Send to Mac"). Invisible: it takes what the sheet hands over,
 * shows a toast and finishes. Text without a stream goes out as a `clipboard` message
 * (PROTOCOL §5); streams are queued in [FileTransfer], which opens them right here while the
 * sheet's temporary read grant is still valid. Nothing is persisted.
 *
 * This is an EXPORTED activity, so it only ever reads what the intent carries — it never
 * touches the clipboard itself (see [ClipHelperActivity]) and accepts `content://` Uris only.
 */
class ShareActivity : Activity() {

    @Suppress("DEPRECATION")        // overridePendingTransition / getParcelableExtra: the replacements are above minSdk
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
        val streams: List<Uri> = when (intent?.action) {
            Intent.ACTION_SEND -> listOfNotNull(
                if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else intent.getParcelableExtra(Intent.EXTRA_STREAM)
            )
            Intent.ACTION_SEND_MULTIPLE -> (
                if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            ).orEmpty()
            else -> { finish(); return }
        }
        val store = Store(this)
        val message = when {
            !Link.isConnected -> getString(R.string.file_not_connected, store.pairedName.ifEmpty { "Mac" })
            streams.isEmpty() -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT).orEmpty()
                val sent = ClipboardBridge(this, store).sendText(text, intent.clipData?.description)
                getString(if (sent) R.string.clip_sent else R.string.clip_offline)
            }
            !store.fileTransfer -> getString(R.string.file_disabled)
            else -> {
                val dropped = FileTransfer.enqueue(this, streams)
                val queued = streams.size - dropped
                if (queued == 0) getString(R.string.file_none_queued)
                else resources.getQuantityString(R.plurals.file_queued, queued, queued) +
                    if (dropped > 0) "\n" + getString(R.string.file_dropped, dropped) else ""
            }
        }
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        finish()
        overridePendingTransition(0, 0)
    }
}
