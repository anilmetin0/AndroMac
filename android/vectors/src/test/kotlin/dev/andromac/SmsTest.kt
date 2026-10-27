package dev.andromac

import dev.andromac.core.Protocol
import dev.andromac.core.Sms
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SmsTest {

    @Test
    fun addressIsDigitsAndPunctuationOnly() {
        assertTrue(Sms.validTo("+905551112233"))
        assertTrue(Sms.validTo("+90 (555) 111-22-33"))
        assertTrue(Sms.validTo("1".repeat(Sms.MAX_TO)))
        assertFalse(Sms.validTo("1".repeat(Sms.MAX_TO + 1)))
        assertFalse(Sms.validTo(""))
        assertFalse(Sms.validTo(" +-() "))            // nothing to dial
        assertFalse(Sms.validTo("VODAFONE"))           // an alphanumeric sender cannot be replied to
        assertFalse(Sms.validTo("*21#"))               // no USSD or call-forwarding codes
        assertFalse(Sms.validTo("5551112233;rm"))
        assertFalse(Sms.validTo("555\n111"))
        assertFalse(Sms.validTo("٥٥٥١١١"))            // Arabic-Indic digits are not on the list
    }

    @Test
    fun bodyIsOneTo2048CodePoints() {
        assertFalse(Sms.validBody(""))
        assertTrue(Sms.validBody("x"))
        assertTrue(Sms.validBody("a".repeat(Sms.MAX_BODY)))
        assertFalse(Sms.validBody("a".repeat(Sms.MAX_BODY + 1)))
        // 2048 emoji are 4096 UTF-16 units but 2048 characters.
        assertTrue(Sms.validBody("😀".repeat(Sms.MAX_BODY)))
    }

    @Test
    fun idIsOneTo64() {
        assertFalse(Sms.validId(""))
        assertTrue(Sms.validId("7c1e"))
        assertTrue(Sms.validId("a".repeat(64)))
        assertFalse(Sms.validId("a".repeat(65)))
    }

    @Test
    fun clipNeverSplitsASurrogatePair() {
        val out = Sms.clip("a".repeat(159) + "😀😀", Sms.MAX_SNIPPET)
        assertEquals("a".repeat(159) + "😀", out)
        assertEquals("short", Sms.clip("short", Sms.MAX_SNIPPET))
    }

    @Test
    fun typeMapsToStatus() {
        assertEquals("received", Sms.status(Sms.TYPE_INBOX))
        assertEquals("sent", Sms.status(Sms.TYPE_SENT))
        assertEquals("pending", Sms.status(Sms.TYPE_OUTBOX))
        assertEquals("pending", Sms.status(Sms.TYPE_QUEUED))
        assertEquals("failed", Sms.status(Sms.TYPE_FAILED))
        assertNull(Sms.status(Sms.TYPE_DRAFT))
        assertNull(Sms.status(0))
    }

    @Test
    fun threadsKeepTheNewestRowAndStopAtFifty() {
        val c = Sms.ThreadCollector()
        assertTrue(c.add(1, 10))
        assertTrue(c.add(1, 9))                       // same thread: the first (newest) row stays
        assertTrue(c.add(2, 8))
        assertEquals(listOf(10L, 8L), c.rowIds())
        val rows = mapOf(10L to Sms.Row("+1", "newest", 300), 8L to Sms.Row("+2", "x".repeat(500), 100))
        val threads = c.threads(rows, mapOf(1L to 3)) { if (it == "+1") "Ayşe" else null }
        assertEquals(listOf(1L, 2L), threads.map { it.thread })
        assertEquals("newest", threads[0].snippet)
        assertEquals(3, threads[0].unread)
        assertEquals("Ayşe", threads[0].name)
        assertEquals(0, threads[1].unread)
        assertNull(threads[1].name)
        assertEquals(Sms.MAX_SNIPPET, threads[1].snippet.length)
        // A row that vanished between the two passes is skipped, not sent half-empty.
        assertEquals(listOf(1L), c.threads(mapOf(10L to Sms.Row("+1", "a", 1))).map { it.thread })

        val many = Sms.ThreadCollector()
        var read = 0
        for (t in 1L..80L) { read++; if (!many.add(t, t)) break }
        assertEquals(Sms.MAX_THREADS, read)          // reading stops at the 50th thread
        assertEquals(Sms.MAX_THREADS, many.rowIds().size)
    }

    @Test
    fun threadsStayUnderTheFrame() {
        val c = Sms.ThreadCollector()
        for (t in 1L..50L) c.add(t, t)
        // An absurd contact name per thread: the list is cut rather than overflowing the frame.
        val huge = "\u0001".repeat(10_000)       // escapes to six bytes each
        val threads = c.threads((1L..50L).associateWith { Sms.Row("+$it", "hi", it) }) { huge }
        assertTrue(threads.size < 50)
        assertEquals(listOf(1L, 2L), threads.take(2).map { it.thread })      // the newest stay
        val json = Protocol.smsThreads(Sms.STATE_OK, threads).toString()
        assertTrue(json.toByteArray().size <= Sms.MAX_PAYLOAD + 1024)
    }

    @Test
    fun messagesStayUnderTheFrame() {
        val c = Sms.MessageCollector()
        val body = "😀".repeat(Sms.MAX_BODY)        // 8 KiB each in UTF-8: 200 would be 1.6 MB
        var read = 0
        for (i in 200L downTo 1L) { read++; if (!c.add(i, body, i, Sms.TYPE_INBOX)) break }
        val out = c.messages()
        assertTrue(out.size < 200)
        assertEquals(200L, out.last().id)           // the newest are kept, still oldest first
        assertEquals(200L - out.size + 1, out.first().id)
        val json = Protocol.smsMessages(42, Sms.STATE_OK, out).toString()
        assertTrue(json.toByteArray().size <= Sms.MAX_PAYLOAD)
        assertTrue(json.toByteArray().size < 1024 * 1024)
        assertFalse(c.add(0, "x", 0, Sms.TYPE_INBOX))   // full stays full
    }

    @Test
    fun messagesAreTheLast200OldestFirst() {
        val c = Sms.MessageCollector()
        assertTrue(c.add(99, "draft", 5_000, Sms.TYPE_DRAFT))   // skipped, does not count
        var read = 0
        for (i in 300L downTo 1L) { read++; if (!c.add(i, "m$i", i, if (i % 2 == 0L) Sms.TYPE_INBOX else Sms.TYPE_SENT)) break }
        assertEquals(Sms.MAX_MESSAGES, read)
        val out = c.messages()
        assertEquals(Sms.MAX_MESSAGES, out.size)
        assertEquals(101L, out.first().id)
        assertEquals(300L, out.last().id)
        assertFalse(out.last().out)
        assertEquals("received", out.last().status)
        assertTrue(out.first().out)
        assertEquals("sent", out.first().status)
    }

    @Test
    fun allPartsMustSucceed() {
        val ok = Sms.Parts(2)
        assertFalse(ok.report(null))
        assertTrue(ok.report(null))
        assertNull(ok.reason)

        val bad = Sms.Parts(3)
        bad.report(null)
        bad.report(Sms.REASON_NO_SERVICE)
        assertTrue(bad.report(Sms.REASON_FAILED))
        assertEquals(Sms.REASON_NO_SERVICE, bad.reason)  // the first failure is the one reported
    }

    @Test
    fun messagesFollowTheSpec() {
        val off = Protocol.smsThreads(Sms.STATE_OFF, listOf(Sms.Thread(1, "+1", null, "x", 1, 0)))
        assertEquals("off", off.getString("state"))
        assertEquals(0, off.getJSONArray("threads").length())   // only `ok` carries a list

        val t = Protocol.smsThreads(Sms.STATE_OK, listOf(Sms.Thread(42, "+905551112233", null, "Yoldayım", 7, 1)))
            .getJSONArray("threads").getJSONObject(0)
        assertFalse(t.has("name"))                   // only when a contact matched
        assertEquals(42L, t.getLong("thread"))

        val m = Protocol.smsMessages(42, Sms.STATE_OK, listOf(Sms.Message(901, "a".repeat(3000), 7, false, "received")))
        assertEquals(Sms.MAX_BODY, m.getJSONArray("messages").getJSONObject(0).getString("body").length)
        assertEquals(42L, m.getLong("thread"))

        assertFalse(Protocol.smsSent("7c1e", true).has("reason"))
        assertEquals("no_service", Protocol.smsSent("7c1e", false, Sms.REASON_NO_SERVICE).getString("reason"))
        assertEquals("sms_changed", Protocol.smsChanged().getString("t"))
        assertTrue("sms" in Protocol.hello("p", true, 0, false).getJSONArray("caps").toList())
    }
}
