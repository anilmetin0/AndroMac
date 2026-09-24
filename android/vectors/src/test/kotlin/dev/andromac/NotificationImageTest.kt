package dev.andromac

import dev.andromac.core.NotificationImage
import dev.andromac.core.Protocol
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class NotificationImageTest {

    @Test
    fun fitShrinksTheLongEdgeAndNeverEnlarges() {
        assertEquals(512 to 384, NotificationImage.fit(4000, 3000, 512))
        assertEquals(96 to 128, NotificationImage.fit(300, 400, 128))
        assertEquals(100 to 50, NotificationImage.fit(100, 50, 512))
        assertEquals(512 to 1, NotificationImage.fit(10000, 1, 512))
        assertEquals(1 to 1, NotificationImage.fit(0, -3, 512))
    }

    @Test
    fun encodePrefersSmallPngForAlphaThenJpegWithOneRetry() {
        val small = ByteArray(1000)
        val big = ByteArray(NotificationImage.MAX_BYTES + 1)
        val qualities = mutableListOf<Int>()

        assertSame(small, NotificationImage.encode(true, { small }, { error("no jpeg") }))

        val jpeg = ByteArray(5000)
        assertSame(jpeg, NotificationImage.encode(true, { big }, { qualities += it; jpeg }))
        assertEquals(listOf(NotificationImage.QUALITY), qualities)

        qualities.clear()
        val retried = NotificationImage.encode(false, { error("no png") }) {
            qualities += it
            if (it == NotificationImage.QUALITY) big else jpeg
        }
        assertSame(jpeg, retried)
        assertEquals(listOf(NotificationImage.QUALITY, NotificationImage.RETRY_QUALITY), qualities)

        assertNull(NotificationImage.encode(false, { error("no png") }) { big })
    }

    @Test
    fun onlyAChangedPictureCountsAsNew() {
        val a = NotificationImage.fingerprint("picture", 2, byteArrayOf(1, 2, 3, 4))
        assertEquals(a, NotificationImage.fingerprint("picture", 2, byteArrayOf(1, 2, 3, 4)))
        assertNotEquals(a, NotificationImage.fingerprint("picture", 2, byteArrayOf(1, 2, 3, 5)))
        assertNotEquals(a, NotificationImage.fingerprint("avatar", 2, byteArrayOf(1, 2, 3, 4)))
        assertNotEquals(a, NotificationImage.fingerprint("picture", 1, byteArrayOf(1, 2, 3, 4)))

        val sent = NotificationImage.Sent()
        assertTrue(sent.isNew("k", a))
        assertFalse(sent.isNew("k", a))            // re-post or text-only update: no picture
        assertTrue(sent.isNew("other", a))          // per notification key
        assertTrue(sent.isNew("k", "b"))
        sent.forget("k")
        assertTrue(sent.isNew("k", "b"))            // removed on the phone, posted again
    }

    private fun message(image: Protocol.Image?, redacted: Boolean = false) = Protocol.notification(
        id = "k", app = "App", pkg = "p", title = "t", text = "x",
        silent = false, redacted = redacted, actions = emptyList(), image = image,
    )

    @Test
    fun theMessageCarriesOnlyAValidUnredactedPicture() {
        val ok = message(Protocol.Image("AAAA", NotificationImage.AVATAR))
        assertEquals("AAAA", ok.getString("img"))
        assertEquals("avatar", ok.getString("img_kind"))

        assertFalse(message(null).has("img"))
        assertFalse(message(Protocol.Image("AAAA", "picture"), redacted = true).has("img"))
        assertFalse(message(Protocol.Image("AAAA", "sticker")).has("img"))
        assertFalse(message(Protocol.Image("", "picture")).has("img"))
        val tooBig = "A".repeat(NotificationImage.MAX_BASE64 + 4)
        assertFalse(message(Protocol.Image(tooBig, "picture")).has("img_kind"))
        assertTrue(message(Protocol.Image("A".repeat(NotificationImage.MAX_BASE64), "picture")).has("img"))
    }
}
