package dev.andromac

import dev.andromac.core.ReconnectPolicy
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ReconnectPolicyTest {
    @Test fun `a cached address must not hide a relaunched Mac forever`() {
        val browses = (1..12).filter { ReconnectPolicy.shouldBrowse(true, it, true) }
        assertTrue(browses == listOf(4, 8, 12))
    }

    @Test fun `a network event always gets fresh discovery`() {
        assertTrue(ReconnectPolicy.shouldBrowse(true, 0, false))
    }

    @Test fun `an unknown endpoint needs discovery even away from the last LAN`() {
        assertTrue((0..12).all { ReconnectPolicy.shouldBrowse(false, it, false) })
    }

    @Test fun `an unrelated network does not repeatedly browse for a cached Mac`() {
        assertFalse((1..12).any { ReconnectPolicy.shouldBrowse(true, it, false) })
    }
}
