package io.github.anilmetin0.andromac

import io.github.anilmetin0.andromac.core.NetworkInfo
import kotlin.test.Test
import kotlin.test.assertEquals

class NetworkInfoTest {

    private fun ip(vararg b: Int) = b.map { it.toByte() }.toByteArray()

    @Test
    fun masksToTheNetworkPart() {
        assertEquals("192.168.1.0/24", NetworkInfo.networkPrefix(ip(192, 168, 1, 42), 24))
        assertEquals("10.0.0.0/8", NetworkInfo.networkPrefix(ip(10, 20, 30, 40), 8))
        // A prefix that does not end on a byte boundary.
        assertEquals("172.16.4.0/22", NetworkInfo.networkPrefix(ip(172, 16, 7, 200), 22))
        assertEquals("192.168.1.42/32", NetworkInfo.networkPrefix(ip(192, 168, 1, 42), 32))
    }
}
