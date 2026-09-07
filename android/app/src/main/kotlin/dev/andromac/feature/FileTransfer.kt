package dev.andromac.feature

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.text.format.Formatter
import android.util.Base64
import android.util.Log
import dev.andromac.R
import dev.andromac.core.FileNames
import dev.andromac.core.Link
import dev.andromac.core.Protocol
import dev.andromac.core.Store
import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * File transfer in both directions (PROTOCOL §5 `file_*`), one transfer at a time per direction.
 *
 * Everything runs on whichever thread calls in — the LinkService read thread for messages,
 * an activity for the share sheet, a BroadcastReceiver for the notification buttons — and
 * serializes on this object. There is no thread of its own and no timer (PROTOCOL §6.12):
 * the next chunk goes out when the ack arrives, progress is repainted at most once a second
 * by comparing timestamps at that moment, and a stalled transfer simply ends with the session.
 *
 * Nothing touches the disk before `file_accept`. Incoming files land in Downloads through
 * MediaStore with IS_PENDING=1 until the hash matches, so no storage permission is needed and
 * a half file is never visible. The file is opened only when the user taps the notification.
 */
object FileTransfer {

    // ---------------------------------------------------------------- sender

    private class Outgoing(
        val id: String, val name: String, val size: Long, val mime: String?, val input: InputStream,
    ) {
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256")
        var seq = 0
        /** The next sequence number an ack is expected for; `seq - acked` is what is in flight. */
        var acked = 0
        var sent = 0L
        var done = false
        var lastUi = 0L
        val buf = ByteArray(Protocol.FILE_CHUNK)
    }

    private val queue = ArrayDeque<Outgoing>()
    private var out: Outgoing? = null

    /**
     * From the share sheet. The streams are opened HERE, while the share grant is valid — the
     * grant dies with the activity, an open descriptor does not. Returns how many were dropped
     * because the queue was full or the Uri could not be opened.
     */
    @Synchronized
    fun enqueue(ctx: Context, uris: List<Uri>): Int {
        val app = ctx.applicationContext
        var dropped = 0
        for (uri in uris) {
            if (queue.size >= MAX_QUEUE) { dropped++; continue }
            val item = open(app, uri)
            if (item == null) dropped++ else queue.addLast(item)
        }
        if (out == null) startNext(app)
        return dropped
    }

    private fun open(ctx: Context, uri: Uri): Outgoing? {
        // Only content:// — a file:// pointing into our own data directory would let any app
        // ship our prefs to the Mac through the exported share target.
        if (uri.scheme != "content") return null
        val r = ctx.contentResolver
        var name: String? = null
        var size = -1L
        runCatching {
            r.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    name = c.getString(0)
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
        }
        if (size < 0) size = runCatching { r.openAssetFileDescriptor(uri, "r")?.use { it.length } }.getOrNull() ?: -1L
        if (size < 0 || size > Protocol.MAX_FILE_SIZE) {
            Log.i(Link.TAG, "share: unknown or oversized file, skipped")
            return null
        }
        val input = runCatching { r.openInputStream(uri) }.getOrNull() ?: return null
        return Outgoing(
            id = ByteArray(16).also(SecureRandom()::nextBytes).hex(),
            name = FileNames.sanitize(name ?: uri.lastPathSegment.orEmpty()),
            size = size,
            mime = r.getType(uri),
            input = input,
        )
    }

    private fun startNext(ctx: Context) {
        val next = queue.removeFirstOrNull() ?: return
        out = next
        if (!Link.send(Protocol.fileOffer(next.id, next.name, next.size, next.mime))) {
            failOut(ctx, R.string.file_failed_send)
            return
        }
        Log.d(Link.TAG, "file offer sent: ${next.name} (${next.size} B)")
        showOutProgress(ctx, next)
    }

    private fun onAccept(ctx: Context, id: String) {
        val o = out?.takeIf { it.id == id } ?: return
        pump(ctx, o)
    }

    private fun onAck(ctx: Context, id: String, seq: Int) {
        val o = out?.takeIf { it.id == id } ?: return
        if (seq != o.acked) { cancelOut(ctx, "out_of_order"); return }
        o.acked++
        pump(ctx, o)
        val now = SystemClock.elapsedRealtime()
        if (out === o && now - o.lastUi >= UI_INTERVAL_MS) { o.lastUi = now; showOutProgress(ctx, o) }
    }

    /**
     * Keep the window full (PROTOCOL §5 step 3): chunks go out until [Protocol.FILE_WINDOW] of them
     * are unacked. With one chunk in flight every 512 KiB cost a full round trip, which on a home
     * network is what limited the transfer rather than the link itself.
     */
    private fun pump(ctx: Context, o: Outgoing) {
        while (o.sent < o.size && o.seq - o.acked < Protocol.FILE_WINDOW) {
            val want = minOf(Protocol.FILE_CHUNK.toLong(), o.size - o.sent).toInt()
            val n = readFully(o.input, o.buf, want)
            if (n != want) { cancelOut(ctx, "read_error"); return }   // the file shrank under us
            o.digest.update(o.buf, 0, n)
            o.sent += n
            val data = Base64.encodeToString(o.buf, 0, n, Base64.NO_WRAP)
            if (!Link.send(Protocol.fileChunk(o.id, o.seq, data))) {
                failOut(ctx, R.string.file_failed_send)
                return
            }
            o.seq++
        }
        // `file_done` goes out on the same connection right after the last chunk, so it arrives
        // after it; the Mac verifies the hash only once every chunk has been written.
        if (o.sent >= o.size && !o.done) { o.done = true; sendDone(ctx, o) }
    }

    private fun sendDone(ctx: Context, o: Outgoing) {
        Link.send(Protocol.fileDone(o.id, o.digest.digest().hex()))
    }

    private fun onResult(ctx: Context, id: String, ok: Boolean) {
        val o = out?.takeIf { it.id == id } ?: return
        closeOut()
        notify(ctx, NOTIF_OUT, if (ok) R.string.file_sent else R.string.file_failed_send, o.name, ongoing = false)
        startNext(ctx)
    }

    private fun cancelOut(ctx: Context, reason: String) {
        val o = out ?: return
        Link.send(Protocol.fileCancel(o.id, reason))
        failOut(ctx, R.string.file_failed_send)
    }

    /** The current file is over without a result: drop it and go on with the queue. */
    private fun failOut(ctx: Context, textRes: Int) {
        val o = out ?: return
        closeOut()
        notify(ctx, NOTIF_OUT, textRes, o.name, ongoing = false)
        startNext(ctx)
    }

    private fun closeOut() {
        out?.let { runCatching { it.input.close() } }
        out = null
    }

    // ---------------------------------------------------------------- receiver

    private class Incoming(val id: String, val name: String, val size: Long, val mime: String?) {
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256")
        var item: Uri? = null
        var output: OutputStream? = null
        var received = 0L
        var seq = 0
        var lastUi = 0L
    }

    /** Offered and waiting for the user's Accept / Decline. Nothing on disk yet. */
    private var pending: Incoming? = null
    private var inc: Incoming? = null

    private fun onOffer(ctx: Context, msg: JSONObject) {
        val id = msg.optString("id")
        if (id.isEmpty() || id.length > 64) return
        val store = Store(ctx)
        val size = msg.optLong("size", -1)
        val reason = when {
            !store.fileTransfer -> "disabled"
            pending != null || inc != null -> "busy"
            size < 0 || size > Protocol.MAX_FILE_SIZE -> "too_large"
            size > freeSpace(ctx) -> "no_space"
            else -> null
        }
        if (reason != null) { Link.send(Protocol.fileReject(id, reason)); return }

        // The MIME type is peer-supplied: it goes into MediaStore and the ACTION_VIEW intent, so
        // accept only a plain `type/subtype` token of sane length; anything else is treated as absent.
        val mime = msg.optString("mime").takeIf { it.length <= 128 && MIME_TOKEN.matches(it) }
        val offer = Incoming(id, FileNames.sanitize(msg.optString("name")), size, mime)
        if (store.fileAutoAccept) { accept(ctx, offer); return }
        pending = offer
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.notify(
            NOTIF_IN,
            builder(ctx)
                .setContentTitle(ctx.getString(R.string.file_offer_title, store.pairedName))
                .setContentText("${offer.name} · ${Formatter.formatShortFileSize(ctx, offer.size)}")
                .setDeleteIntent(action(ctx, ACTION_DECLINE, id))
                .addAction(actionButton(ctx, R.string.file_accept, ACTION_ACCEPT, id))
                .addAction(actionButton(ctx, R.string.file_decline, ACTION_DECLINE, id))
                .build()
        )
    }

    private fun accept(ctx: Context, offer: Incoming) {
        val r = ctx.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val name = FileNames.unique(offer.name) { candidate ->
            r.query(
                collection, arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME}=?", arrayOf(candidate), null,
            )?.use { it.count > 0 } ?: false
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            offer.mime?.let { put(MediaStore.MediaColumns.MIME_TYPE, it) }
        }
        val item = runCatching { r.insert(collection, values) }.getOrNull()
        val output = item?.let { runCatching { r.openOutputStream(it, "w") }.getOrNull() }
        if (item == null || output == null) {
            Log.w(Link.TAG, "could not create the Downloads entry")
            item?.let { runCatching { r.delete(it, null, null) } }
            Link.send(Protocol.fileReject(offer.id, "write_error"))
            return
        }
        offer.item = item
        offer.output = output
        inc = offer
        Link.send(Protocol.fileAccept(offer.id))
        showInProgress(ctx, offer)
    }

    private fun onChunk(ctx: Context, msg: JSONObject) {
        val i = inc?.takeIf { it.id == msg.optString("id") } ?: return   // not accepted: ignored, nothing allocated
        if (msg.optInt("seq", -1) != i.seq) { cancelIn(ctx, "out_of_order"); return }
        val data = runCatching { Base64.decode(msg.optString("data"), Base64.DEFAULT) }.getOrNull()
        if (data == null || data.size > Protocol.FILE_CHUNK) { cancelIn(ctx, "bad_chunk"); return }
        if (i.received + data.size > i.size) { cancelIn(ctx, "overshoot"); return }
        try {
            i.output!!.write(data)
        } catch (e: Exception) {
            Log.w(Link.TAG, "write failed: ${e.message}")
            cancelIn(ctx, "write_error")
            return
        }
        i.digest.update(data)
        i.received += data.size
        i.seq++
        Link.send(Protocol.fileAck(i.id, i.seq - 1))
        val now = SystemClock.elapsedRealtime()
        if (now - i.lastUi >= UI_INTERVAL_MS) { i.lastUi = now; showInProgress(ctx, i) }
    }

    private fun onDone(ctx: Context, msg: JSONObject) {
        val i = inc?.takeIf { it.id == msg.optString("id") } ?: return
        val r = ctx.contentResolver
        val closed = runCatching { i.output?.close() }.isSuccess
        val hash = i.digest.digest().hex()
        val ok = closed && i.received == i.size && hash == msg.optString("sha256").lowercase()
        if (!ok) {
            Log.i(Link.TAG, "file rejected: size ${i.received}/${i.size}, hash ${if (closed) "mismatch" else "n/a"}")
            discardIn(ctx)
            Link.send(Protocol.fileResult(i.id, false, if (closed) "hash_mismatch" else "write_error"))
            return
        }
        val published = runCatching {
            r.update(i.item!!, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null) > 0
        }.getOrDefault(false)
        if (!published) {
            discardIn(ctx)
            Link.send(Protocol.fileResult(i.id, false, "write_error"))
            return
        }
        val item = i.item!!
        inc = null
        Link.send(Protocol.fileResult(i.id, true))
        Log.d(Link.TAG, "file received: ${i.name}")
        val view = PendingIntent.getActivity(
            ctx, REQ_VIEW,
            Intent(Intent.ACTION_VIEW).setDataAndType(item, i.mime ?: "*/*")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        ctx.getSystemService(NotificationManager::class.java).notify(
            // One notification per file, so an earlier one is not overwritten before it was seen.
            NOTIF_RECEIVED_BASE + (ContentUris.parseId(item) % 1000).toInt(),
            builder(ctx)
                .setContentTitle(ctx.getString(R.string.file_received))
                .setContentText(i.name)
                .setSubText(ctx.getString(R.string.file_received_tap))
                .setContentIntent(view)
                .setAutoCancel(true)
                .build()
        )
    }

    private fun cancelIn(ctx: Context, reason: String) {
        val i = inc ?: return
        Link.send(Protocol.fileCancel(i.id, reason))
        discardIn(ctx)
        notify(ctx, NOTIF_IN, R.string.file_failed_receive, i.name, ongoing = false)
    }

    /** Closes and deletes the pending Downloads entry; nothing of it was ever visible. */
    private fun discardIn(ctx: Context) {
        val i = inc ?: return
        inc = null
        runCatching { i.output?.close() }
        i.item?.let { runCatching { ctx.contentResolver.delete(it, null, null) } }
        ctx.getSystemService(NotificationManager::class.java).cancel(NOTIF_IN)
    }

    // ---------------------------------------------------------------- entry points

    /** Every `file_*` message from the Mac lands here, on the LinkService read thread. */
    @Synchronized
    fun handle(ctx: Context, msg: JSONObject) {
        val app = ctx.applicationContext
        val id = msg.optString("id")
        when (msg.optString("t")) {
            Protocol.T_FILE_OFFER -> onOffer(app, msg)
            Protocol.T_FILE_CHUNK -> onChunk(app, msg)
            Protocol.T_FILE_DONE -> onDone(app, msg)
            Protocol.T_FILE_ACCEPT -> onAccept(app, id)
            Protocol.T_FILE_ACK -> onAck(app, id, msg.optInt("seq", -1))
            Protocol.T_FILE_RESULT -> onResult(app, id, msg.optBoolean("ok", false))
            Protocol.T_FILE_REJECT -> if (out?.id == id) {
                Log.i(Link.TAG, "file rejected by the Mac: ${msg.optString("reason")}")
                failOut(app, if (msg.optString("reason") == "declined") R.string.file_declined else R.string.file_failed_send)
            }
            Protocol.T_FILE_CANCEL -> when (id) {
                out?.id -> failOut(app, R.string.file_failed_send)
                inc?.id -> {
                    val name = inc?.name.orEmpty()
                    discardIn(app)
                    notify(app, NOTIF_IN, R.string.file_failed_receive, name, ongoing = false)
                }
                pending?.id -> { pending = null; app.getSystemService(NotificationManager::class.java).cancel(NOTIF_IN) }
            }
        }
    }

    /** The notification buttons. */
    @Synchronized
    fun userAction(ctx: Context, action: String, id: String) {
        val app = ctx.applicationContext
        when (action) {
            ACTION_ACCEPT -> pending?.takeIf { it.id == id }?.let { pending = null; accept(app, it) }
            ACTION_DECLINE -> pending?.takeIf { it.id == id }?.let {
                pending = null
                app.getSystemService(NotificationManager::class.java).cancel(NOTIF_IN)
                Link.send(Protocol.fileReject(id, "declined"))
            }
            ACTION_CANCEL_IN -> if (inc?.id == id) {
                Link.send(Protocol.fileCancel(id, "user"))
                discardIn(app)
            }
            ACTION_CANCEL_OUT -> if (out?.id == id) {
                Link.send(Protocol.fileCancel(id, "user"))
                closeOut()
                app.getSystemService(NotificationManager::class.java).cancel(NOTIF_OUT)
                startNext(app)
            }
        }
    }

    /** From LinkService's `finally`: nothing is resumed, temporary files go (PROTOCOL §5 step 6). */
    @Synchronized
    fun onSessionEnded(ctx: Context) {
        val app = ctx.applicationContext
        val nm = app.getSystemService(NotificationManager::class.java)
        if (inc != null || pending != null) { pending = null; discardIn(app); nm.cancel(NOTIF_IN) }
        if (out != null || queue.isNotEmpty()) {
            closeOut()
            queue.forEach { runCatching { it.input.close() } }
            queue.clear()
            nm.cancel(NOTIF_OUT)
        }
    }

    // ---------------------------------------------------------------- helpers

    private fun freeSpace(ctx: Context): Long =
        runCatching { StatFs((ctx.getExternalFilesDir(null) ?: ctx.filesDir).path).availableBytes }
            .getOrDefault(Long.MAX_VALUE)   // unknown: let MediaStore's own write error decide

    private fun readFully(input: InputStream, buf: ByteArray, len: Int): Int {
        var off = 0
        while (off < len) {
            val n = try { input.read(buf, off, len - off) } catch (e: Exception) { return off }
            if (n < 0) break
            off += n
        }
        return off
    }

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    // ---------------------------------------------------------------- notifications

    private fun builder(ctx: Context): Notification.Builder {
        ctx.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, ctx.getString(R.string.file_channel), NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = ctx.getString(R.string.file_channel_desc) }
        )
        return Notification.Builder(ctx, CHANNEL).setSmallIcon(R.drawable.ic_notification)
    }

    private fun action(ctx: Context, action: String, id: String): PendingIntent = PendingIntent.getBroadcast(
        ctx, 0,
        Intent(ctx, FileActionReceiver::class.java).setAction(action).putExtra(EXTRA_ID, id),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun actionButton(ctx: Context, titleRes: Int, action: String, id: String) =
        Notification.Action.Builder(null as Icon?, ctx.getString(titleRes), action(ctx, action, id)).build()

    private fun showInProgress(ctx: Context, i: Incoming) =
        progress(ctx, NOTIF_IN, ctx.getString(R.string.file_receiving, i.name), i.received, i.size, ACTION_CANCEL_IN, i.id)

    private fun showOutProgress(ctx: Context, o: Outgoing) =
        progress(ctx, NOTIF_OUT, ctx.getString(R.string.file_sending, o.name), o.sent, o.size, ACTION_CANCEL_OUT, o.id)

    private fun progress(ctx: Context, notifId: Int, title: String, done: Long, total: Long, cancel: String, id: String) {
        val pct = if (total == 0L) 100 else (done * 100 / total).toInt()
        ctx.getSystemService(NotificationManager::class.java).notify(
            notifId,
            builder(ctx)
                .setContentTitle(title)
                .setContentText("${Formatter.formatShortFileSize(ctx, done)} / ${Formatter.formatShortFileSize(ctx, total)}")
                .setProgress(100, pct, false)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .addAction(actionButton(ctx, R.string.file_cancel, cancel, id))
                .build()
        )
    }

    private fun notify(ctx: Context, notifId: Int, titleRes: Int, name: String, ongoing: Boolean) {
        ctx.getSystemService(NotificationManager::class.java).notify(
            notifId,
            builder(ctx).setContentTitle(ctx.getString(titleRes)).setContentText(name)
                .setOngoing(ongoing).setAutoCancel(!ongoing).build()
        )
    }

    const val CHANNEL = "files"
    private val MIME_TOKEN = Regex("[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+")
    const val ACTION_ACCEPT = "dev.andromac.FILE_ACCEPT"
    const val ACTION_DECLINE = "dev.andromac.FILE_DECLINE"
    const val ACTION_CANCEL_IN = "dev.andromac.FILE_CANCEL_IN"
    const val ACTION_CANCEL_OUT = "dev.andromac.FILE_CANCEL_OUT"
    const val EXTRA_ID = "id"
    private const val NOTIF_IN = 10
    private const val NOTIF_OUT = 11
    private const val NOTIF_RECEIVED_BASE = 1000
    private const val REQ_VIEW = 6
    private const val MAX_QUEUE = 50
    private const val UI_INTERVAL_MS = 1_000L
}

/** Accept / Decline / Cancel from the notifications. exported=false in the manifest. */
class FileActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        FileTransfer.userAction(context, action, intent.getStringExtra(FileTransfer.EXTRA_ID).orEmpty())
    }
}
