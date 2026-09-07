package dev.andromac.feature

import dev.andromac.core.Version
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
 * (docs/ENERGY.md rule 1). One HTTPS GET to api.github.com; the request carries the app version
 * in the User-Agent and nothing else.
 *
 * There is one rolling release per version (tag `v1.0.0`, title `AndroMac 1.0.0 (fd7d47a)`),
 * re-published on every push with a new commit, so "newer" means a greater version or the same
 * version built from another commit — see [isNewer].
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
    private const val MAX_BODY = 256 * 1024
    private val COMMIT = Regex("""\(([0-9a-fA-F]{7,40})\)""")

    /** One published file of a release: what the in-app updater downloads. */
    data class Asset(val name: String, val url: String, val size: Long)

    data class Release(
        val version: Version,
        val commit: String?,
        val url: String,
        val assets: List<Asset> = emptyList(),
    ) {
        /** `1.0.0 (fd7d47a)`, or just `1.0.0` when the title carried no commit. */
        val label: String get() = if (commit == null) version.toString() else "$version ($commit)"

        /** The Android build of this release, `AndroMac-<version>-<commit>.apk`. */
        val apk: Asset? get() = assets.firstOrNull { it.name.endsWith(".apk") }

        /** The checksum file every release publishes. The updater refuses to install without it. */
        val checksums: Asset? get() = assets.firstOrNull { it.name == "SHA256SUMS.txt" }
    }

    /** Returns the response body, null for 404, throws for anything else. */
    fun interface Fetch { fun get(url: String): String? }

    /** The latest release when [isNewer] than the running build, or null when up to date. */
    fun newest(current: Version, currentCommit: String?, fetch: Fetch): Release? =
        fetch.get("$API/latest")?.let(::parse)?.takeIf { isNewer(it, current, currentCommit) }

    /**
     * A greater version is always newer. The same version is newer only when both commits are
     * known, the running build is not a local one, and the commits differ (case-insensitive).
     */
    fun isNewer(release: Release, current: Version, currentCommit: String?): Boolean =
        release.version > current ||
            (release.version == current && release.commit != null && currentCommit != null &&
                currentCommit != LOCAL_COMMIT && !release.commit.equals(currentCommit, ignoreCase = true))

    /** One GitHub release object → [Release]; null when it carries no version or points elsewhere. */
    fun parse(json: String): Release? {
        val o = JSONObject(json)
        // The link is opened in the browser: only ever a page of this repository, whatever the
        // response says.
        val url = o.optString("html_url")
        if (!url.startsWith("https://github.com/$REPO/")) return null
        val name = o.optString("name")
        val version = Version.find(o.optString("tag_name")) ?: Version.find(name) ?: return null
        return Release(version, COMMIT.find(name)?.groupValues?.get(1), url, assets(o))
    }

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
    fun checkAsync(current: Version, currentCommit: String?, done: (Result<Release?>) -> Unit) {
        val fetch = Fetch { url -> https(url, "AndroMac/$current") }
        Thread({ done(runCatching { newest(current, currentCommit, fetch) }) }, "andromac-update")
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
