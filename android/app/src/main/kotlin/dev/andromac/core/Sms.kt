package dev.andromac.core

/**
 * The Android-free half of Messages (PROTOCOL §5 `sms_*`): limits, what the Mac may send, and how
 * provider rows become threads and messages. Kept apart from feature/SmsBridge.kt so the JVM
 * `vectors` module can test it.
 */
object Sms {
    const val MAX_THREADS = 50
    const val MAX_SNIPPET = 160
    const val MAX_MESSAGES = 200
    const val MAX_BODY = 2048
    const val MAX_ID = 64
    const val MAX_TO = 32

    const val STATE_OK = "ok"
    const val STATE_OFF = "off"
    const val STATE_NO_PERMISSION = "no_permission"

    const val REASON_OFF = "off"
    const val REASON_NO_PERMISSION = "no_permission"
    const val REASON_INVALID = "invalid"
    const val REASON_NO_SERVICE = "no_service"
    const val REASON_FAILED = "failed"

    const val STATUS_RECEIVED = "received"
    const val STATUS_SENT = "sent"
    const val STATUS_PENDING = "pending"
    const val STATUS_FAILED = "failed"

    /** `Telephony.Sms.MESSAGE_TYPE_*`, repeated here because that class is Android-only. */
    const val TYPE_INBOX = 1
    const val TYPE_SENT = 2
    const val TYPE_DRAFT = 3
    const val TYPE_OUTBOX = 4
    const val TYPE_FAILED = 5
    const val TYPE_QUEUED = 6

    private val address = Regex("^[0-9 +()\\-]+$")

    /** Digits, spaces, `+`, `-`, `(` and `)`, at most 32, and at least one digit to dial. */
    fun validTo(to: String): Boolean =
        to.length <= MAX_TO && address.matches(to) && to.any { it in '0'..'9' }

    /** 1 to 2048 characters, counted as code points so an emoji is one, not two. */
    fun validBody(body: String): Boolean =
        body.isNotEmpty() && body.codePointCount(0, body.length) <= MAX_BODY

    fun validId(id: String): Boolean = id.isNotEmpty() && id.length <= MAX_ID

    /** [text] cut to [max] code points, never through the middle of a surrogate pair. */
    fun clip(text: String, max: Int): String =
        if (text.codePointCount(0, text.length) <= max) text
        else text.substring(0, text.offsetByCodePoints(0, max))

    /** Null for a draft or an unknown type: those are not shown. */
    fun status(type: Int): String? = when (type) {
        TYPE_INBOX -> STATUS_RECEIVED
        TYPE_SENT -> STATUS_SENT
        TYPE_OUTBOX, TYPE_QUEUED -> STATUS_PENDING
        TYPE_FAILED -> STATUS_FAILED
        else -> null
    }

    data class Thread(
        val thread: Long, val addr: String, val name: String?, val snippet: String, val ts: Long, val unread: Int,
    )

    data class Message(val id: Long, val body: String, val ts: Long, val out: Boolean, val status: String)

    /**
     * What a payload may add up to: under the 1 MiB frame (PROTOCOL §4) with room for the
     * envelope. 200 bodies of 2048 emoji would be 1.6 MB, so the oldest messages give way first.
     */
    const val MAX_PAYLOAD = 900 * 1024

    /** Keys, numbers and punctuation of one entry, on top of its strings. */
    private const val ENTRY_OVERHEAD = 128

    /** [text] as it goes on the wire: JSON-escaped, in UTF-8 bytes. */
    fun wireSize(text: String): Int = org.json.JSONObject.quote(text).toByteArray(Charsets.UTF_8).size

    /**
     * The conversation list, in two passes so the scan never reads a message body. Pass one walks
     * row ids newest first, [add] keeps the first (latest) row of each thread and returns false
     * once [MAX_THREADS] threads are in, so the cursor is left there. Pass two reads just those
     * rows ([rowIds]) in full.
     */
    class ThreadCollector {
        private val latest = LinkedHashMap<Long, Long>()

        val full: Boolean get() = latest.size >= MAX_THREADS

        fun add(thread: Long, rowId: Long): Boolean {
            if (full) return false
            latest.putIfAbsent(thread, rowId)
            return !full
        }

        fun rowIds(): List<Long> = latest.values.toList()

        /**
         * Newest first, from the full rows by row id. Unread counts come from a separate, small
         * query of unread inbox rows. Whatever would not fit in [MAX_PAYLOAD] is left out at the
         * old end.
         */
        fun threads(rows: Map<Long, Row>, unread: Map<Long, Int> = emptyMap(), name: (String) -> String? = { null }): List<Thread> {
            var bytes = 0
            val out = ArrayList<Thread>()
            for ((thread, rowId) in latest) {
                val row = rows[rowId] ?: continue
                val t = Thread(thread, row.addr, name(row.addr), clip(row.body, MAX_SNIPPET), row.ts, unread[thread] ?: 0)
                bytes += ENTRY_OVERHEAD + wireSize(t.addr) + wireSize(t.name.orEmpty()) + wireSize(t.snippet)
                if (bytes > MAX_PAYLOAD) break
                out += t
            }
            return out
        }
    }

    /** One thread's latest message, as pass two of [ThreadCollector] reads it. */
    data class Row(val addr: String, val body: String, val ts: Long)

    /**
     * Rows read newest first, as the provider returns them: the 200 most recent shown messages,
     * oldest first. Drafts and unknown types are dropped before they count, and reading stops
     * where the next message would take the payload past [MAX_PAYLOAD].
     */
    class MessageCollector {
        private val newestFirst = ArrayList<Message>()
        private var bytes = 0
        private var overBudget = false

        val full: Boolean get() = overBudget || newestFirst.size >= MAX_MESSAGES

        fun add(id: Long, body: String, ts: Long, type: Int): Boolean {
            if (full) return false
            val status = status(type) ?: return true
            val clipped = clip(body, MAX_BODY)
            val size = ENTRY_OVERHEAD + wireSize(clipped)
            if (bytes + size > MAX_PAYLOAD) {
                overBudget = true
                return false
            }
            bytes += size
            newestFirst += Message(id, clipped, ts, type != TYPE_INBOX, status)
            return !full
        }

        fun messages(): List<Message> = newestFirst.asReversed().toList()
    }

    /** Several parts, one answer: true only when every part was sent. */
    class Parts(private var left: Int) {
        var reason: String? = null
            private set

        /** Records one part; returns true when it was the last one. */
        fun report(failure: String?): Boolean {
            if (failure != null && reason == null) reason = failure
            left--
            return left <= 0
        }
    }
}
