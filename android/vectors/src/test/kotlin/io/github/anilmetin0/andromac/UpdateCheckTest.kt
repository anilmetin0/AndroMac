package io.github.anilmetin0.andromac

import io.github.anilmetin0.andromac.core.Version
import io.github.anilmetin0.andromac.feature.UpdateCheck
import io.github.anilmetin0.andromac.feature.UpdateCheck.Release
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
    fun tagTargetBeatsTheTitle() {
        val title = "\"name\":\"AndroMac 1.0.1 (fd7d47a)\","
        val hash = UpdateCheck.parse(latest.replace(title,
            "\"name\":\"AndroMac 1.0.1\",\"target_commitish\":\"E355642A1B2C3D4E5F60718293A4B5C6D7E8F901\","))
        assertEquals("e355642", hash?.commit)
        val branch = UpdateCheck.parse(latest.replace(title, "\"name\":\"AndroMac 1.0.1\",\"target_commitish\":\"main\","))
        assertNull(branch?.commit)
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

    private fun rel(v: Version, build: Int?, beta: Boolean = false) = Release(v, "fd7d47a", url, build = build, prerelease = beta)

    @Test
    fun stableIsNewerByVersionThenBuild() {
        assertTrue(UpdateCheck.isNewer(rel(v101, 12), v101, 11, "abc1234"))
        assertFalse(UpdateCheck.isNewer(rel(v101, 11), v101, 11, "abc1234"))
        assertTrue(UpdateCheck.isNewer(rel(Version(1, 0, 2), 3), v101, 11, "abc1234"))
        assertFalse(UpdateCheck.isNewer(rel(Version(1, 0, 0), 99), v101, 11, "abc1234"))
    }

    /** A beta user switching back to stable keeps the newer beta until a stable build passes it. */
    @Test
    fun stableNeverOffersALowerBuild() {
        assertFalse(UpdateCheck.isNewer(rel(v101, 10), v101, 15, "abc1234"))
    }

    @Test
    fun betaIsNewerByBuildWithoutGoingBackAVersion() {
        assertTrue(UpdateCheck.isNewer(rel(v101, 16, beta = true), v101, 15, "abc1234", beta = true))
        assertFalse(UpdateCheck.isNewer(rel(v101, 15, beta = true), v101, 15, "abc1234", beta = true))
        assertFalse(UpdateCheck.isNewer(rel(Version(1, 0, 0), 99), v101, 15, "abc1234", beta = true))
        assertTrue(UpdateCheck.isNewer(rel(Version(1, 1, 0), 16, beta = true), v101, 15, "abc1234", beta = true))
    }

    @Test
    fun localBuildOrUnknownBuildOnlyCountsAGreaterVersion() {
        for (mine in listOf("local", "", null)) {
            assertFalse(UpdateCheck.isNewer(rel(v101, 50), v101, 1, mine))
            assertTrue(UpdateCheck.isNewer(rel(Version(1, 0, 2), 50), v101, 1, mine))
        }
        assertFalse(UpdateCheck.isNewer(rel(v101, null), v101, 1, "abc1234"))
        assertTrue(UpdateCheck.isNewer(rel(Version(1, 0, 2), null), v101, 1, "abc1234"))
    }

    @Test
    fun betaChannelPicksTheHighestBuild() {
        val list = listOf(rel(v101, 20), rel(v101, 23, beta = true), rel(v101, null), rel(v101, 21, beta = true))
        assertEquals(23, UpdateCheck.newestBuild(list)?.build)
        assertNull(UpdateCheck.newestBuild(listOf(rel(v101, null))))
    }

    @Test
    fun buildComesFromTheFooterThenTheBetaTag() {
        assertEquals(212, UpdateCheck.build("notes\n\n<sub>Build 212 · commit fd7d47a · APK signing: release</sub>", "v1.0.1"))
        assertEquals(213, UpdateCheck.build("", "beta-213-fd7d47a"))
        assertNull(UpdateCheck.build("Build 1234567890 · commit x", "v1.0.1"))
        assertNull(UpdateCheck.build("", "v1.0.1"))
    }

    private val withFooter = latest.replace("\"prerelease\":false}",
        "\"prerelease\":false,\"body\":\"<sub>Build 40 · commit fd7d47a</sub>\"}")

    @Test
    fun stableFetchesOnlyLatestAndAppliesTheRule() {
        val urls = mutableListOf<String>()
        val fetch = UpdateCheck.Fetch { u -> urls += u; if (u.endsWith("/latest")) withFooter else null }
        assertEquals("1.0.1 (fd7d47a)", UpdateCheck.newest(v101, 39, "abc1234", false, fetch)?.label)
        assertNull(UpdateCheck.newest(v101, 40, "fd7d47a", false, fetch))
        assertNull(UpdateCheck.newest(Version(1, 0, 2), 1, "abc1234", false, fetch))
        assertEquals(listOf("https://api.github.com/repos/anilmetin0/AndroMac/releases/latest"), urls.distinct())
    }

    @Test
    fun betaFetchesTheListAndTakesTheHighestBuild() {
        val beta = """{"tag_name":"beta-41-abc1234","name":"AndroMac 1.0.1 beta 41 (abc1234)","prerelease":true,
            "html_url":"https://github.com/anilmetin0/AndroMac/releases/tag/beta-41-abc1234",
            "assets":[{"name":"AndroMac-beta-41-android.apk","size":1,
              "browser_download_url":"https://github.com/anilmetin0/AndroMac/releases/download/beta-41-abc1234/AndroMac-beta-41-android.apk"}]}"""
        val urls = mutableListOf<String>()
        val fetch = UpdateCheck.Fetch { u -> urls += u; "[$withFooter,$beta]" }
        val r = UpdateCheck.newest(v101, 40, "fd7d47a", true, fetch)
        assertEquals(41, r?.build)
        assertTrue(r!!.prerelease)
        assertEquals("1.0.1 beta 41 (abc1234)", r.label)
        assertEquals("AndroMac-beta-41-android.apk", r.apk?.name)
        assertNull(UpdateCheck.newest(v101, 41, "abc1234", true, fetch))
        assertEquals(listOf("https://api.github.com/repos/anilmetin0/AndroMac/releases?per_page=10"), urls.distinct())
    }

    @Test
    fun missingReleaseIsNotAnError() {
        assertNull(UpdateCheck.newest(Version(1, 0, 0), 1, "abc1234", false, UpdateCheck.Fetch { null }))
    }

    private val body = """
        ## What's new

        - Faster pairing, **bold** and [a link](https://example.com)


        <details>
        <summary><b>Türkçe</b></summary>

        ## Yenilikler

        - Daha hızlı eşleşme
        </details>

        ## Changes in this build

        - fix(macos): run one copy at a time (d6125ce)

        **Install:** see the [README](https://github.com/anilmetin0/AndroMac#install) · 
        **Kurulum:** [README.tr](https://github.com/anilmetin0/AndroMac/blob/main/README.tr.md#kurulum)

        <sub>Build 212 · commit fd7d47a · APK signing: release · checksums in SHA256SUMS.txt</sub>
    """.trimIndent()

    @Test
    fun englishNotesDropTheTurkishBlockAndTheHtml() {
        assertEquals(
            "## What's new\n\n- Faster pairing, **bold** and [a link](https://example.com)\n\n" +
                "## Changes in this build\n\n- fix(macos): run one copy at a time (d6125ce)",
            UpdateCheck.notes(body, turkish = false),
        )
    }

    @Test
    fun turkishNotesKeepTheFoldedBlockAndTheBuildChanges() {
        assertEquals(
            "## Yenilikler\n\n- Daha hızlı eşleşme\n\n" +
                "## Changes in this build\n\n- fix(macos): run one copy at a time (d6125ce)",
            UpdateCheck.notes(body, turkish = true),
        )
        assertEquals("- one", UpdateCheck.notes("- one\n", turkish = true))
    }

    @Test
    fun inlineMarkdownKeepsOnlyTheText() {
        assertEquals("Faster pairing, bold and a link, code", UpdateCheck.inline("Faster pairing, **bold** and [a link](https://example.com), `code`"))
    }

    @Test
    fun notesAreBounded() {
        val r = UpdateCheck.parse(latest.replace("\"prerelease\":false}", "\"prerelease\":false,\"body\":\"${"x".repeat(50_000)}\"}"))
        assertEquals(UpdateCheck.MAX_NOTES, r?.body?.length)
    }

    @Test
    fun parsesTheAssetsTheUpdaterNeeds() {
        val json = """
            {"tag_name":"v1.0.1","name":"AndroMac 1.0.1 (fd7d47a)",
             "html_url":"https://github.com/anilmetin0/AndroMac/releases/tag/v1.0.1",
             "assets":[
               {"name":"AndroMac-1.0.1-android.apk","size":4242,
                "browser_download_url":"https://github.com/anilmetin0/AndroMac/releases/download/v1.0.1/AndroMac-1.0.1-android.apk"},
               {"name":"SHA256SUMS.txt","size":120,
                "browser_download_url":"https://github.com/anilmetin0/AndroMac/releases/download/v1.0.1/SHA256SUMS.txt"}]}
        """.trimIndent()
        val release = UpdateCheck.parse(json)!!
        assertEquals(2, release.assets.size)
        assertEquals("AndroMac-1.0.1-android.apk", release.apk?.name)
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
