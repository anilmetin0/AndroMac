package dev.andromac

import dev.andromac.core.Version
import dev.andromac.feature.UpdateCheck
import dev.andromac.feature.UpdateCheck.Release
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class UpdateCheckTest {

    private val latest = """{"tag_name":"v1.0.1","name":"AndroMac 1.0.1 (fd7d47a)",
        "html_url":"https://github.com/anilmetin0/AndroMac/releases/tag/v1.0.1","prerelease":false}"""

    private val v101 = Version(1, 0, 1)
    private val url = "https://github.com/anilmetin0/AndroMac/releases/tag/v1.0.1"

    @Test
    fun parsesVersionAndCommit() {
        val r = UpdateCheck.parse(latest)
        assertEquals(v101, r?.version)
        assertEquals("fd7d47a", r?.commit)
        assertEquals("1.0.1 (fd7d47a)", r?.label)
    }

    @Test
    fun nameWithoutParenthesesHasNoCommit() {
        val r = UpdateCheck.parse(latest.replace(" (fd7d47a)", ""))
        assertEquals(v101, r?.version)
        assertNull(r?.commit)
        assertEquals("1.0.1", r?.label)
    }

    @Test
    fun refusesALinkOutsideTheRepository() {
        val foreign = latest.replace("github.com/anilmetin0/AndroMac", "example.com/x")
        assertNull(UpdateCheck.parse(foreign))
    }

    @Test
    fun greaterVersionIsNewerRegardlessOfCommit() {
        assertTrue(UpdateCheck.isNewer(Release(v101, null, url), Version(1, 0, 0), "fd7d47a"))
        assertTrue(UpdateCheck.isNewer(Release(v101, "fd7d47a", url), Version(1, 0, 0), null))
        assertTrue(UpdateCheck.isNewer(Release(v101, "fd7d47a", url), Version(1, 0, 0), "local"))
        assertFalse(UpdateCheck.isNewer(Release(Version(1, 0, 0), "abc1234", url), v101, "fd7d47a"))
    }

    @Test
    fun sameVersionDifferentCommitIsNewer() {
        assertTrue(UpdateCheck.isNewer(Release(v101, "fd7d47a", url), v101, "abc1234"))
    }

    @Test
    fun sameVersionSameCommitIsNotNewer() {
        assertFalse(UpdateCheck.isNewer(Release(v101, "fd7d47a", url), v101, "fd7d47a"))
        assertFalse(UpdateCheck.isNewer(Release(v101, "FD7D47A", url), v101, "fd7d47a"))
        // Unknown on either side: nothing to compare, so not newer.
        assertFalse(UpdateCheck.isNewer(Release(v101, null, url), v101, "fd7d47a"))
        assertFalse(UpdateCheck.isNewer(Release(v101, "fd7d47a", url), v101, null))
    }

    @Test
    fun localBuildOnlyCountsAGreaterVersion() {
        assertFalse(UpdateCheck.isNewer(Release(v101, "fd7d47a", url), v101, "local"))
        assertTrue(UpdateCheck.isNewer(Release(Version(1, 0, 2), "fd7d47a", url), v101, "local"))
    }

    @Test
    fun newestFetchesOnlyLatestAndAppliesTheRule() {
        val urls = mutableListOf<String>()
        val fetch = UpdateCheck.Fetch { u -> urls += u; if (u.endsWith("/latest")) latest else null }
        assertEquals("1.0.1 (fd7d47a)", UpdateCheck.newest(v101, "abc1234", fetch)?.label)
        assertNull(UpdateCheck.newest(v101, "fd7d47a", fetch))
        assertNull(UpdateCheck.newest(Version(1, 0, 2), "abc1234", fetch))
        assertEquals(listOf("https://api.github.com/repos/anilmetin0/AndroMac/releases/latest"), urls.distinct())
    }

    @Test
    fun missingReleaseIsNotAnError() {
        assertNull(UpdateCheck.newest(Version(1, 0, 0), "abc1234", UpdateCheck.Fetch { null }))
    }
    @Test
    fun parsesTheAssetsTheUpdaterNeeds() {
        val json = """
            {"tag_name":"v1.0.1","name":"AndroMac 1.0.1 (fd7d47a)",
             "html_url":"https://github.com/anilmetin0/AndroMac/releases/tag/v1.0.1",
             "assets":[
               {"name":"AndroMac-1.0.1-fd7d47a.apk","size":4242,
                "browser_download_url":"https://github.com/anilmetin0/AndroMac/releases/download/v1.0.1/AndroMac-1.0.1-fd7d47a.apk"},
               {"name":"SHA256SUMS.txt","size":120,
                "browser_download_url":"https://github.com/anilmetin0/AndroMac/releases/download/v1.0.1/SHA256SUMS.txt"}]}
        """.trimIndent()
        val release = UpdateCheck.parse(json)!!
        assertEquals(2, release.assets.size)
        assertEquals("AndroMac-1.0.1-fd7d47a.apk", release.apk?.name)
        assertEquals(4242L, release.apk?.size)
        assertEquals("SHA256SUMS.txt", release.checksums?.name)
    }

    /** The updater downloads whatever this returns, so anything served elsewhere is dropped. */
    @Test
    fun assetsFromElsewhereAreDropped() {
        val json = """
            {"tag_name":"v1.0.1","name":"AndroMac 1.0.1 (fd7d47a)",
             "html_url":"https://github.com/anilmetin0/AndroMac/releases/tag/v1.0.1",
             "assets":[
               {"name":"AndroMac-1.0.1.apk",
                "browser_download_url":"https://example.com/AndroMac-1.0.1.apk"},
               {"name":"../escape.apk",
                "browser_download_url":"https://github.com/anilmetin0/AndroMac/releases/download/v1.0.1/x.apk"}]}
        """.trimIndent()
        val release = UpdateCheck.parse(json)!!
        assertTrue(release.assets.isEmpty())
        assertNull(release.apk)
    }
}
