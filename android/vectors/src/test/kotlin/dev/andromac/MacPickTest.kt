package dev.andromac

import dev.andromac.core.MacPick
import dev.andromac.core.MacPick.Peer
import java.net.InetAddress
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MacPickTest {

    private fun peer(service: String, ip: String, name: String = service) =
        Peer(InetAddress.getByName(ip), 50_000, service, name)

    private val mine = peer("Anıl's MacBook Pro", "192.168.1.10")
    private val arda = peer("Arda's MacBook Air", "192.168.1.20")

    @Test
    fun ourMacGoesFirstWhateverOrderTheBrowseReturned() {
        assertEquals(listOf(mine, arda), MacPick.dialOrder(listOf(arda, mine), mine.name, emptySet(), null))
    }

    @Test
    fun aMacProvenNotOursIsNeverDialledAgain() {
        assertEquals(emptyList(), MacPick.dialOrder(listOf(arda), mine.name, setOf(arda.id), null))
        // Same name, other address: a different machine, so it is still a candidate.
        val moved = peer(arda.service, "192.168.1.21")
        assertEquals(listOf(moved), MacPick.dialOrder(listOf(moved), mine.name, setOf(arda.id), null))
    }

    @Test
    fun theChosenMacIsTheOnlyOneDialledForPairing() {
        assertEquals(listOf(arda), MacPick.dialOrder(listOf(mine, arda), "", emptySet(), arda.service))
        assertEquals(emptyList(), MacPick.dialOrder(listOf(mine), "", emptySet(), arda.service))
    }

    @Test
    fun onlyOurMacsNameMakesAMismatchAKeyChange() {
        assertFalse(MacPick.isKeyChange(arda.name, mine.name))
        assertTrue(MacPick.isKeyChange(mine.name, mine.name))       // our Mac, reinstalled
        assertTrue(MacPick.isKeyChange(arda.name, ""))              // nothing to compare with
    }

    @Test
    fun aSameNameNeighbourIsSkippedWhileAnotherOfThatNameIsLeft() {
        val twin = peer("Anıl's MacBook Pro (2)", "192.168.1.30", name = mine.name)
        // Our name, and another Mac of our name still to dial: this one is the neighbour's.
        assertTrue(MacPick.skipOnMismatch(twin, mine.name, listOf(mine, arda)))
        // The last Mac of our name: now it is a key change.
        assertFalse(MacPick.skipOnMismatch(mine, mine.name, listOf(arda)))
        assertFalse(MacPick.skipOnMismatch(mine, mine.name, emptyList()))
        // Another name is skipped whatever is left.
        assertTrue(MacPick.skipOnMismatch(arda, mine.name, emptyList()))
        // Nothing saved to compare with: every mismatch is a key change.
        assertFalse(MacPick.skipOnMismatch(arda, "", listOf(mine)))
    }
}
