package dev.andromac

import dev.andromac.core.Version
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class VersionTest {

    @Test
    fun parsesEveryFormThePipelineProduces() {
        assertEquals(Version(1, 0, 0), Version.find("v1.0.0"))
        assertEquals(Version(1, 0, 1, 42), Version.find("Development build 1.0.1-dev.42"))
        assertEquals(Version(1, 0, 0), Version.find("1.0.0 (12 · abc1234)"))
        assertEquals(Version(2, 10, 3), Version.find("AndroMac-2.10.3-macOS.zip"))
    }

    @Test
    fun rejectsWhatIsNotAVersion() {
        assertNull(Version.find("dev"))
        assertNull(Version.find("1.0"))
        assertNull(Version.find(""))
    }

    @Test
    fun stableOutranksItsOwnDevBuilds() {
        assertTrue(Version(1, 0, 1, 99) < Version(1, 0, 1))
        assertTrue(Version(1, 0, 0) < Version(1, 0, 1, 1))
        assertTrue(Version(1, 0, 1, 1) < Version(1, 0, 1, 2))
        assertTrue(Version(1, 9, 9) < Version(2, 0, 0))
        assertTrue(Version(1, 0, 10) > Version(1, 0, 9))
    }

    @Test
    fun roundTripsThroughToString() {
        for (text in listOf("1.0.0", "1.0.1-dev.42", "12.34.56")) {
            assertEquals(text, Version.find(text).toString())
        }
    }
}
