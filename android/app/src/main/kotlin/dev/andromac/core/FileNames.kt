package dev.andromac.core

/**
 * Receiver-side file name rules from PROTOCOL §5, applied to whatever the sender claims.
 * Pure Kotlin so the vectors module can unit-test it on a plain JVM.
 */
object FileNames {

    private const val MAX_BYTES = 255
    private const val FALLBACK = "file"

    /**
     * Last path component only, no control or invisible format characters, no leading dots or
     * whitespace, at most 255 bytes of UTF-8 (the stem is cut, the extension kept), `file` when
     * nothing is left. Format characters (category Cf) are the bidi overrides and zero-width
     * ones, which can make `x\u202Egnp.apk` read as `xkpa.png`.
     */
    fun sanitize(name: String): String {
        var s = name.substringAfterLast('/').substringAfterLast('\\')
        s = buildString {
            s.codePoints().forEach { cp ->
                if (cp >= 0x20 && cp != 0x7F && Character.getType(cp) != Character.FORMAT.toInt()) appendCodePoint(cp)
            }
        }
        s = s.trimStart { it == '.' || it.isWhitespace() }.trimEnd()
        if (s.isEmpty()) return FALLBACK
        if (s.toByteArray().size <= MAX_BYTES) return s

        val (stem, ext) = split(s)
        // An absurdly long "extension" is not one; cut the whole name instead.
        val keepExt = ext.toByteArray().size <= 32
        val budget = MAX_BYTES - if (keepExt) ext.toByteArray().size else 0
        val cut = truncateUtf8(if (keepExt) stem else s, budget).trimEnd { it == '.' || it.isWhitespace() }
        val out = if (keepExt) cut + ext else cut
        return out.ifEmpty { FALLBACK }
    }

    /** `photo.jpg` -> `photo (2).jpg` while [exists] says the name is taken. Counts from 2, like Finder. */
    fun unique(name: String, exists: (String) -> Boolean): String {
        if (!exists(name)) return name
        val (stem, ext) = split(name)
        var n = 2
        while (true) {
            val candidate = "$stem ($n)$ext"
            if (!exists(candidate)) return candidate
            n++
        }
    }

    /** ("photo", ".jpg"); a name with no dot, or only a leading one, has no extension. */
    private fun split(name: String): Pair<String, String> {
        val dot = name.lastIndexOf('.')
        return if (dot <= 0) name to "" else name.substring(0, dot) to name.substring(dot)
    }

    /** Longest prefix that fits [bytes] of UTF-8 without cutting a code point. */
    private fun truncateUtf8(s: String, bytes: Int): String {
        var used = 0
        val out = StringBuilder()
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            val len = String(Character.toChars(cp)).toByteArray().size
            if (used + len > bytes) break
            out.appendCodePoint(cp)
            used += len
            i += Character.charCount(cp)
        }
        return out.toString()
    }
}
