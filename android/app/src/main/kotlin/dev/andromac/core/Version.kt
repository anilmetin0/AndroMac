package dev.andromac.core

/**
 * A version as the release pipeline writes it: `1.0.0`. A `-dev.N` suffix is still parsed and
 * ordered below the plain number (`1.0.1-dev.42 < 1.0.1`), so a build that carried one can
 * update to the release. Pure Kotlin so the vectors module can test it, and so the macOS side
 * ([AppVersion]) can mirror it line for line.
 */
data class Version(val major: Int, val minor: Int, val patch: Int, val dev: Int? = null) : Comparable<Version> {

    val isDev: Boolean get() = dev != null

    override fun compareTo(other: Version): Int = compareValuesBy(
        this, other, { it.major }, { it.minor }, { it.patch }, { it.dev ?: Int.MAX_VALUE },
    )

    override fun toString(): String = "$major.$minor.$patch" + (dev?.let { "-dev.$it" } ?: "")

    companion object {
        private val PATTERN = Regex("""(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?:-dev\.(\d{1,9}))?""")

        /**
         * The first version inside any text: a tag (`v1.0.0`), a release title
         * (`Development build 1.0.1-dev.42`) or the label the apps show (`1.0.0 (12 · abc1234)`).
         */
        fun find(text: String): Version? {
            val m = PATTERN.find(text) ?: return null
            val (major, minor, patch, dev) = m.destructured
            return Version(major.toInt(), minor.toInt(), patch.toInt(), dev.toIntOrNull())
        }
    }
}
