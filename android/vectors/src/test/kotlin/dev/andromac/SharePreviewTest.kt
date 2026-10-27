package dev.andromac

import dev.andromac.feature.SharePreview
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SharePreviewTest {

    @Test
    fun shortTextIsShownWhole() {
        assertEquals("hello", SharePreview.of("  hello\n"))
        assertEquals("", SharePreview.of(" \n "))
        val exact = "a".repeat(SharePreview.MAX)
        assertEquals(exact, SharePreview.of(exact))
    }

    @Test
    fun longTextIsCutWithAnEllipsis() {
        val out = SharePreview.of("a".repeat(5_000))
        assertEquals(SharePreview.MAX + 1, out.length)
        assertTrue(out.endsWith("…"))
    }

    @Test
    fun neverSplitsASurrogatePair() {
        // "😀" is two UTF-16 units; the cut would land between them.
        val out = SharePreview.of("a".repeat(SharePreview.MAX - 1) + "😀" + "b".repeat(10))
        assertEquals("a".repeat(SharePreview.MAX - 1) + "…", out)
        assertTrue(out.none { Character.isSurrogate(it) })
    }
}
