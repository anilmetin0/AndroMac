package io.github.anilmetin0.andromac.feature

import java.util.concurrent.CopyOnWriteArrayList

/**
 * The last [MAX] texts sent to and received from the Mac, newest first, for the history screen.
 *
 * Memory only: nothing is written to disk and it is gone with the process. Clips marked
 * sensitive on the phone never enter it ([ClipboardBridge.sendText]). The wire carries no such mark
 * for incoming text; the Mac holds back concealed clips by default.
 */
object ClipHistory {

    class Entry(val text: String, val fromMac: Boolean, val time: Long)

    private const val MAX = 20
    private val entries = ArrayDeque<Entry>()
    private val listeners = CopyOnWriteArrayList<() -> Unit>()

    /** The same text again moves to the top instead of filling the list with copies. */
    fun add(text: String, fromMac: Boolean) {
        synchronized(entries) {
            entries.removeAll { it.text == text }
            entries.addFirst(Entry(text, fromMac, System.currentTimeMillis()))
            while (entries.size > MAX) entries.removeLast()
        }
        listeners.forEach { runCatching { it() } }
    }

    fun list(): List<Entry> = synchronized(entries) { entries.toList() }

    fun clear() {
        synchronized(entries) { entries.clear() }
        listeners.forEach { runCatching { it() } }
    }

    fun addListener(l: () -> Unit) { listeners += l }
    fun removeListener(l: () -> Unit) { listeners -= l }
}
