package dev.andromac.core

import org.json.JSONArray
import org.json.JSONObject

/** The docs/PROTOCOL.md §5 message builders. Unknown types are dropped silently by the caller. */
object Protocol {
    const val VERSION = 3

    const val T_HELLO = "hello"
    const val T_BATTERY = "battery"
    const val T_CLIPBOARD = "clipboard"
    const val T_NOTIFICATION = "notification"
    const val T_NOTIFICATION_REMOVE = "notification_remove"
    const val T_NOTIFICATION_DISMISS = "notification_dismiss"
    const val T_NOTIFICATION_ACTION = "notification_action"
    const val T_APP_MODES = "app_modes"
    const val T_APP_MODE = "app_mode"
    const val T_ICON_REQUEST = "icon_request"
    const val T_APP_ICON = "app_icon"
    const val T_PING = "ping"
    const val T_PONG = "pong"
    const val T_FIND_PHONE = "find_phone"
    const val T_MEDIA = "media"
    const val T_MEDIA_CONTROL = "media_control"
    const val T_FILE_OFFER = "file_offer"
    const val T_FILE_ACCEPT = "file_accept"
    const val T_FILE_REJECT = "file_reject"
    const val T_FILE_CHUNK = "file_chunk"
    const val T_FILE_ACK = "file_ack"
    const val T_FILE_DONE = "file_done"
    const val T_FILE_RESULT = "file_result"
    const val T_FILE_CANCEL = "file_cancel"
    const val T_SYSTEM = "system"
    const val T_SYSTEM_CONTROL = "system_control"
    const val T_CLIPBOARD_REQUEST = "clipboard_request"

    /** File transfer (PROTOCOL §5): one chunk per frame, 512 KiB raw is ~683 KiB as base64, under the 1 MiB frame cap. */
    const val FILE_CHUNK = 512 * 1024

    /** How many chunks may be unacked at once (PROTOCOL §5 step 3): 4 MiB in flight. */
    const val FILE_WINDOW = 8
    const val MAX_FILE_SIZE = 4L shl 30

    /** Upper bound on a clipboard payload. Anything longer is truncated — it must stay below the 1 MiB frame limit. */
    const val MAX_CLIPBOARD = 64 * 1024

    /**
     * Notification field limits from PROTOCOL §8. The receiver truncates to these anyway, so
     * clamping here keeps a long `EXTRA_BIG_TEXT` body off the radio instead of sending
     * kilobytes the Mac will only discard.
     */
    const val MAX_NOTIFICATION_TEXT = 2048
    const val MAX_NOTIFICATION_ID = 256

    fun hello(name: String) = JSONObject()
        .put("t", T_HELLO)
        .put("name", name)
        .put("platform", "android")
        .put("proto", VERSION)
        .put(
            "caps",
            JSONArray(
                listOf(
                    "battery", "clipboard", "notification", "find_phone", "media", "file", "system",
                )
            ),
        )

    fun battery(level: Int, charging: Boolean, status: String, tempC: Double?) = JSONObject()
        .put("t", T_BATTERY)
        .put("level", level)
        .put("charging", charging)
        .put("status", status)
        .apply { if (tempC != null) put("temp", tempC) }
        .put("ts", System.currentTimeMillis())

    /** Ringer and media volume, plus whether Do Not Disturb access lets the Mac silence the phone. */
    fun system(ringer: String, volume: Int, volumeMax: Int, canSilence: Boolean) = JSONObject()
        .put("t", T_SYSTEM)
        .put("ringer", ringer)
        .put("volume", volume)
        .put("volume_max", volumeMax)
        .put("can_silence", canSilence)

    fun clipboard(text: String) = JSONObject()
        .put("t", T_CLIPBOARD)
        .put("text", text.take(MAX_CLIPBOARD))
        .put("ts", System.currentTimeMillis())

    fun notification(
        id: String, app: String, pkg: String, title: String, text: String,
        silent: Boolean, redacted: Boolean, actions: List<Action>,
    ) = JSONObject()
        .put("t", T_NOTIFICATION)
        .put("id", id.take(MAX_NOTIFICATION_ID))
        .put("app", app.take(MAX_NOTIFICATION_ID))
        .put("pkg", pkg.take(MAX_NOTIFICATION_ID))
        .put("title", title.take(MAX_NOTIFICATION_TEXT))
        .put("text", text.take(MAX_NOTIFICATION_TEXT))
        .put("silent", silent)
        .put("redacted", redacted)
        .put("actions", JSONArray(actions.map { it.json() }))
        .put("ts", System.currentTimeMillis())

    /** One notification action. When [reply] is true the Mac may show a text field. */
    data class Action(val title: String, val reply: Boolean) {
        fun json(): JSONObject = JSONObject().put("title", title).put("reply", reply)
    }

    fun notificationRemove(id: String) = JSONObject()
        .put("t", T_NOTIFICATION_REMOVE)
        .put("id", id)

    /** The Mac asks when it sees a package it has no icon for; we send it once and the Mac caches it. */
    fun appIcon(pkg: String, pngBase64: String) = JSONObject()
        .put("t", T_APP_ICON)
        .put("pkg", pkg)
        .put("png", pngBase64)

    /** The complete set of app modes; sent on connect and on every change. */
    fun appModes(apps: List<AppMode>) = JSONObject()
        .put("t", T_APP_MODES)
        .put("apps", JSONArray(apps.map { it.json() }))

    data class AppMode(val pkg: String, val label: String, val mode: Int) {
        fun json(): JSONObject = JSONObject()
            .put("pkg", pkg).put("label", label).put("mode", mode)
    }

    /**
     * The active media session. Deliberately has NO `ts`: the message is sent only on change
     * (PROTOCOL §6.10) and is suppressed when the body is byte-for-byte identical — a
     * timestamp would defeat that de-duplication.
     */
    fun media(
        active: Boolean,
        playing: Boolean,
        title: String,
        artist: String,
        album: String,
        app: String,
        pkg: String,
    ) = JSONObject()
        .put("t", T_MEDIA)
        .put("active", active)
        .put("playing", playing)
        .put("title", title)
        .put("artist", artist)
        .put("album", album)
        .put("app", app)
        .put("pkg", pkg)

    /** No session, or the user turned media off. The Mac panel hides its media block. */
    fun mediaInactive() = JSONObject()
        .put("t", T_MEDIA)
        .put("active", false)

    fun pong() = JSONObject().put("t", T_PONG)

    // --- file transfer, PROTOCOL §5 `file_*` ---

    fun fileOffer(id: String, name: String, size: Long, mime: String?) = JSONObject()
        .put("t", T_FILE_OFFER)
        .put("id", id)
        .put("name", name)
        .put("size", size)
        .apply { if (!mime.isNullOrEmpty()) put("mime", mime) }

    fun fileAccept(id: String) = JSONObject().put("t", T_FILE_ACCEPT).put("id", id)

    fun fileReject(id: String, reason: String) = JSONObject()
        .put("t", T_FILE_REJECT).put("id", id).put("reason", reason)

    fun fileChunk(id: String, seq: Int, dataBase64: String) = JSONObject()
        .put("t", T_FILE_CHUNK).put("id", id).put("seq", seq).put("data", dataBase64)

    fun fileAck(id: String, seq: Int) = JSONObject().put("t", T_FILE_ACK).put("id", id).put("seq", seq)

    fun fileDone(id: String, sha256Hex: String) = JSONObject()
        .put("t", T_FILE_DONE).put("id", id).put("sha256", sha256Hex)

    fun fileResult(id: String, ok: Boolean, reason: String? = null) = JSONObject()
        .put("t", T_FILE_RESULT).put("id", id).put("ok", ok)
        .apply { if (reason != null) put("reason", reason) }

    fun fileCancel(id: String, reason: String) = JSONObject()
        .put("t", T_FILE_CANCEL).put("id", id).put("reason", reason)

    /** Chunks a file of [size] bytes needs: 0 for an empty file, which goes straight to `file_done`. */
    fun fileChunkCount(size: Long): Long = (size + FILE_CHUNK - 1) / FILE_CHUNK
}
