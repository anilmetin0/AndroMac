package dev.andromac.feature

/**
 * The excerpt the share-sheet confirmation shows ([dev.andromac.ui.ShareActivity]): enough to
 * recognise the text, short enough for a dialog. Pure Kotlin, tested in `:vectors:test`.
 */
object SharePreview {

    const val MAX = 280

    /** Trimmed, at most [max] characters plus `…`, never cutting a surrogate pair in half. */
    fun of(text: String, max: Int = MAX): String {
        val t = text.trim()
        if (t.length <= max) return t
        val end = if (Character.isHighSurrogate(t[max - 1])) max - 1 else max
        return t.substring(0, end).trimEnd() + "…"
    }
}
