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

    @Test fun `a first refusal on the cached address browses at once`() {
        assertTrue(ReconnectPolicy.shouldBrowse(true, 1, true, cachedRefused = true))
        assertTrue(ReconnectPolicy.shouldBrowse(true, 3, false, cachedRefused = true))
    }

    @Test fun `only a refused connection counts as a moved port`() {
        assertTrue(ReconnectPolicy.isRefusal(java.net.ConnectException("connect failed: ECONNREFUSED (Connection refused)")))
        assertTrue(ReconnectPolicy.isRefusal(java.net.ConnectException("Connection refused")))
        assertFalse(ReconnectPolicy.isRefusal(java.net.ConnectException("connect failed: EHOSTUNREACH (No route to host)")))
        assertFalse(ReconnectPolicy.isRefusal(java.net.SocketTimeoutException("connect timed out")))
    }
}
