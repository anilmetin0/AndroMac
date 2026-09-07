package dev.andromac

import dev.andromac.core.FileNames
import dev.andromac.core.Protocol
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class FileNamesTest {

    @Test
    fun keepsOnlyTheLastPathComponent() {
        assertEquals("passwd", FileNames.sanitize("../../etc/passwd"))
        assertEquals("y.txt", FileNames.sanitize("C:\\x\\y.txt"))
        assertEquals("a.txt", FileNames.sanitize("/a.txt"))
    }

    @Test
    fun dropsControlCharsAndLeadingDots() {
        assertEquals("ab.txt", FileNames.sanitize("a\u0000b\u001f.txt\u007f"))
        assertEquals("hidden", FileNames.sanitize("...hidden"))
        assertEquals("x", FileNames.sanitize(" \t. x "))
    }

    @Test
    fun fallsBackToFile() {
        assertEquals("file", FileNames.sanitize(""))
        assertEquals("file", FileNames.sanitize("."))
        assertEquals("file", FileNames.sanitize(".."))
        assertEquals("file", FileNames.sanitize("dir/"))
        assertEquals("file", FileNames.sanitize("\u0001\u0002"))
    }

    @Test
    fun capsAt255BytesKeepingTheExtension() {
        val long = "a".repeat(300) + ".jpeg"
        val out = FileNames.sanitize(long)
        assertTrue(out.endsWith(".jpeg"))
        assertEquals(255, out.toByteArray().size)

        // Multi-byte stem: never cut inside a code point.
        val turkish = "ş".repeat(200) + ".txt"
        val t = FileNames.sanitize(turkish)
        assertTrue(t.endsWith(".txt"))
        assertTrue(t.toByteArray().size <= 255)
        assertEquals(t, String(t.toByteArray()))

        // No real extension: the whole thing is cut.
        assertEquals(255, FileNames.sanitize("b".repeat(400)).toByteArray().size)
    }

    @Test
    fun uniqueSuffixGoesBeforeTheExtension() {
        val taken = setOf("photo.jpg", "photo (2).jpg", "notes")
        assertEquals("photo (3).jpg", FileNames.unique("photo.jpg", taken::contains))
        assertEquals("notes (2)", FileNames.unique("notes", taken::contains))
        assertEquals("new.jpg", FileNames.unique("new.jpg", taken::contains))
    }

    @Test
    fun chunkCount() {
        val chunk = Protocol.FILE_CHUNK.toLong()
        assertEquals(0, Protocol.fileChunkCount(0))
        assertEquals(1, Protocol.fileChunkCount(1))
        assertEquals(1, Protocol.fileChunkCount(chunk))
        assertEquals(2, Protocol.fileChunkCount(chunk + 1))
    }
}
