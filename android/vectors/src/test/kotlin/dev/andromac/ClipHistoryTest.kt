package dev.andromac

import dev.andromac.feature.ClipHistory
import kotlin.test.Test
import kotlin.test.assertEquals

class ClipHistoryTest {

    @Test
    fun boundedNewestFirstAndDeduplicated() {
        ClipHistory.clear()
        repeat(25) { ClipHistory.add("t$it", fromMac = it % 2 == 0) }
        val list = ClipHistory.list()
        assertEquals(20, list.size)
        assertEquals("t24", list.first().text)
        assertEquals("t5", list.last().text)

        ClipHistory.add("t10", fromMac = true)       // a repeat moves up, it is not stored twice
        assertEquals(listOf("t10", "t24"), ClipHistory.list().take(2).map { it.text })
        assertEquals(20, ClipHistory.list().size)

        ClipHistory.clear()
        assertEquals(0, ClipHistory.list().size)
    }
}
