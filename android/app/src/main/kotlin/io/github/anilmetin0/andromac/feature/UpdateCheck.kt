package io.github.anilmetin0.andromac.feature

import io.github.anilmetin0.andromac.core.Version
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/**
 * Finds the newest AndroMac release on GitHub.
 *
 * This is the ONLY code in the app that talks to anything beyond the local network, and it runs
 * solely when the user turned it on and opens the app — no timer, no background job
 * (docs/ENERGY.md rule 1). One HTTPS GET to api.github.com per check (`releases/latest`, or
 * `releases?per_page=10` on the beta channel); the request carries the app version in the
 * User-Agent and nothing else.
 *
 * A stable release per version (tag `v1.0.0`, title `AndroMac 1.0.0`) is marked latest; every
 * other push publishes a beta (tag `beta-212-fd7d47a`, title `AndroMac 1.0.0 beta 212 (fd7d47a)`),
 * a prerelease. Every body ends with a `Build 212 · commit fd7d47a` footer, which is where the
 * build number is read. What "newer" means is [isNewer].
 *
 * Plain JVM code (no Android API) so the vectors module can unit-test the parsing and the
 * newer-rule with a fake [Fetch].
 */
object UpdateCheck {

    const val REPO = "anilmetin0/AndroMac"

    /** What local builds report as their commit; they cannot be compared to a release. */
    const val LOCAL_COMMIT = "local"

    /** Once a day is plenty, and stays far below GitHub's unauthenticated rate limit. */
    const val INTERVAL_MS = 24L * 60 * 60 * 1000

    private const val API = "https://api.github.com/repos/$REPO/releases"
    private const val TIMEOUT_MS = 10_000
    private const val MAX_BODY = 1024 * 1024
    /** 20 000 characters: a long changelog is a few thousand. */
    const val MAX_NOTES = 20_000
    private val COMMIT = Regex("""\(([0-9a-fA-F]{7,40})\)""")
    private val FOOTER_BUILD = Regex("""Build (\d{1,9}) · commit""")
    private val BETA_TAG = Regex("""^beta-(\d{1,9})-""")

    /** One published file of a release: what the in-app updater downloads. */
    data class Asset(val name: String, val url: String, val size: Long)

    data class Release(
        val version: Version,
        val commit: String?,
        val url: String,
        val assets: List<Asset> = emptyList(),
        /** The CI run that built it, from the body's footer or a `beta-N-sha` tag; null if neither says. */
        val build: Int? = null,
        /** A beta: published on every push, never marked latest. */
        val prerelease: Boolean = false,
        /** The release body, at most [MAX_NOTES] characters. [notes] cleans it for display. */
        val body: String = "",
    ) {
        /** `1.0.0 (fd7d47a)`, `1.0.0 beta 212 (fd7d47a)`, or just `1.0.0` when no commit is known. */
        val label: String get() {
            val base = if (prerelease) "$version beta ${build ?: "?"}" else version.toString()
            return if (commit == null) base else "$base ($commit)"
        }

        /**
         * The Android build of this release: `AndroMac-<version>-android.apk`, or
         * `AndroMac-beta-<build>-android.apk` for a beta. One APK for every ABI: there is no native code.
         */
        val apk: Asset? get() = assets.firstOrNull { it.name.startsWith("AndroMac-") && it.name.endsWith("-android.apk") }

        /** The checksum file every release publishes. The updater refuses to install without it. */
        val checksums: Asset? get() = assets.firstOrNull { it.name == "SHA256SUMS.txt" }
    }

    /** Returns the response body, null for 404, throws for anything else. */
    fun interface Fetch { fun get(url: String): String? }

    /**
     * The release to offer when it [isNewer] than the running build, or null when up to date.
     * Stable reads `releases/latest`, which never returns a prerelease; beta reads the last ten
     * releases and takes the highest build ([newestBuild]).
     */
    fun newest(current: Version, currentBuild: Int, currentCommit: String?, beta: Boolean, fetch: Fetch): Release? {
        val release = if (beta) fetch.get("$API?per_page=10")?.let { newestBuild(parseList(it)) }
        else fetch.get("$API/latest")?.let(::parse)
        return release?.takeIf { isNewer(it, current, currentBuild, currentCommit, beta) }
    }

    /**
     * Stable: a greater version, or the same version with a greater build. Never a lower build,
     * so a beta user who switches back to stable is not "updated" to an older build of the same
     * version. Beta: a greater build whose version is not lower. A local build (commit "local" or
     * unknown) has a meaningless build number, so only a greater version counts for it; the same
     * goes for a release without a build number.
     */
    fun isNewer(release: Release, current: Version, currentBuild: Int, currentCommit: String?, beta: Boolean = false): Boolean {
        val theirs = release.build
        if (currentCommit.isNullOrEmpty() || currentCommit == LOCAL_COMMIT || theirs == null) return release.version > current
        if (beta) return theirs > currentBuild && release.version >= current
        return release.version > current || (release.version == current && theirs > currentBuild)
    }

    /** The beta channel's pick: the highest build, beta or stable. */
    fun newestBuild(releases: List<Release>): Release? = releases.filter { it.build != null }.maxByOrNull { it.build!! }

    /** One GitHub release object → [Release]; null when it carries no version or points elsewhere. */
    fun parse(json: String): Release? = parse(JSONObject(json))

    /** The array `releases?per_page=N` returns, keeping the entries [parse] accepts. */
    fun parseList(json: String): List<Release> {
        val array = JSONArray(json)
        return (0 until array.length()).mapNotNull { i -> array.optJSONObject(i)?.let(::parse) }
    }

    private fun parse(o: JSONObject): Release? {
        // The link is opened in the browser: only ever a page of this repository, whatever the
        // response says.
        val url = o.optString("html_url")
        if (!url.startsWith("https://github.com/$REPO/")) return null
        val name = o.optString("name")
        val tag = o.optString("tag_name")
        val version = Version.find(tag) ?: Version.find(name) ?: return null
        val body = o.optString("body")
        return Release(
            version, commitOf(o.optString("target_commitish")) ?: COMMIT.find(name)?.groupValues?.get(1), url,
            assets(o), build(body, tag), o.optBoolean("prerelease", false), body.take(MAX_NOTES),
        )
    }

    /** The footer every body ends with (`Build 212 · commit fd7d47a`), else a `beta-212-sha` tag. */
    fun build(body: String, tag: String): Int? =
        (FOOTER_BUILD.findAll(body.takeLast(2000)).lastOrNull() ?: BETA_TAG.find(tag))?.groupValues?.get(1)?.toIntOrNull()

    /**
     * The body as the update dialog shows it: Markdown, without the HTML the release page uses
     * (`<details>`, `<summary>`, the `<sub>` footer) or the install links. The body has the
     * English notes, the Turkish ones folded in `<details>`, then "Changes in this build".
     * English drops the folded block; Turkish drops what comes before it, and falls back to
     * English when there is no folded block. Mirrors `Release.notes(turkish:)` on the Mac.
     */
    fun notes(body: String, turkish: Boolean): String {
        val english = ArrayList<String>()
        val folded = ArrayList<String>()
        var inside = false
        var seen = false
        for (raw in body.take(MAX_NOTES).split('\n')) {
            val t = raw.trim()
            when {
                t.startsWith("<details") -> { inside = true; seen = true; continue }
                t.startsWith("</details") -> { inside = false; continue }
                t.startsWith("<summary") || t.startsWith("<sub>") ||
                    t.startsWith("**Install:**") || t.startsWith("**Kurulum:**") -> continue
            }
            val line = if (t.isEmpty()) "" else raw.trimEnd('\r').replace(TAG, "")
            if (!inside) english += line
            if (seen) folded += line
        }
        // Runs of blank lines collapse into one, and none at either end.
        val out = ArrayList<String>()
        for (line in if (turkish && seen) folded else english) {
            if (line.isEmpty() && (out.lastOrNull()?.isEmpty() != false)) continue
            out += line
        }
        while (out.lastOrNull()?.isEmpty() == true) out.removeAt(out.lastIndex)
        return out.joinToString("\n")
    }

    /** One line of Markdown as plain text: `**bold**`, `` `code` `` and `[text](url)` keep only their text. */
    fun inline(text: String): String =
        text.replace(LINK, "$1").replace(EMPHASIS, "$2").replace(CODE, "$1")

    private val TAG = Regex("""</?[a-zA-Z][^<>]{0,40}>""")
    private val LINK = Regex("""\[([^\]]{1,200})]\([^)\s]{1,500}\)""")
    private val EMPHASIS = Regex("""(\*\*|__)(.{1,500}?)\1""")
    private val CODE = Regex("""`([^`]{1,500})`""")

    /** The short form of the tag's target when it is a commit hash; a branch name gives null. */
    private fun commitOf(target: String): String? =
        if (target.length >= 7 && target.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' })
            target.substring(0, 7).lowercase() else null

    /**
     * The downloadable files, keeping only what GitHub itself serves from this repository: an asset
     * URL pointing anywhere else is not something the app will fetch, whatever the response says.
     */
    private fun assets(release: JSONObject): List<Asset> {
        val array = release.optJSONArray("assets") ?: return emptyList()
        val out = ArrayList<Asset>(array.length())
        for (i in 0 until array.length()) {
            val a = array.optJSONObject(i) ?: continue
            val name = a.optString("name")
            val url = a.optString("browser_download_url")
            if (name.isEmpty() || '/' in name) continue
            if (!url.startsWith("https://github.com/$REPO/releases/download/")) continue
            out.add(Asset(name, url, a.optLong("size", 0)))
        }
        return out
    }

    /** Runs [newest] off the calling thread; [done] is invoked on that worker thread. */
    fun checkAsync(current: Version, currentBuild: Int, currentCommit: String?, beta: Boolean,
                   done: (Result<Release?>) -> Unit) {
        val fetch = Fetch { url -> https(url, "AndroMac/$current") }
        Thread({ done(runCatching { newest(current, currentBuild, currentCommit, beta, fetch) }) }, "andromac-update")
            .apply { isDaemon = true }
            .start()
    }

    private fun https(url: String, userAgent: String): String? {
        val conn = URL(url).openConnection() as HttpsURLConnection
        conn.connectTimeout = TIMEOUT_MS
        conn.readTimeout = TIMEOUT_MS
        conn.setRequestProperty("Accept", "application/vnd.github+json")
        conn.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
        conn.setRequestProperty("User-Agent", userAgent)
        try {
            when (val code = conn.responseCode) {
                404 -> return null
                200 -> Unit
                else -> throw IOException("HTTP $code")
            }
            // Bounded read: the response is trusted for its content, not for its size.
            val out = ByteArrayOutputStream()
            val buf = ByteArray(8192)
            conn.inputStream.use { input ->
                while (out.size() < MAX_BODY) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                }
            }
            return out.toString("UTF-8")
        } finally {
            conn.disconnect()
        }
    }
}
