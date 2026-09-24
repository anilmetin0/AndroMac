package dev.andromac.core

import java.security.MessageDigest
import kotlin.math.roundToInt

/**
 * The picture a mirrored notification may carry (PROTOCOL §5 `notification.img`, ENERGY rule 26).
 * Android-free, so the size, format and "did it change" rules run on a plain JVM (:vectors).
 */
object NotificationImage {
    const val PICTURE = "picture"
    const val AVATAR = "avatar"

    /** Encoded size cap. The Mac drops anything larger, so it is never put on the radio. */
    const val MAX_BYTES = 96 * 1024
    const val MAX_BASE64 = (MAX_BYTES + 2) / 3 * 4
    const val PICTURE_EDGE = 512
    const val AVATAR_EDGE = 128
    const val QUALITY = 70
    const val RETRY_QUALITY = 40

    /** PNG only to keep transparency, and only this small; everything else goes as JPEG. */
    const val SMALL_PNG = 32 * 1024

    /** [width]×[height] shrunk to [edge] on the long side, aspect kept; never enlarged, never 0. */
    fun fit(width: Int, height: Int, edge: Int): Pair<Int, Int> {
        val w = width.coerceAtLeast(1)
        val h = height.coerceAtLeast(1)
        val long = maxOf(w, h)
        if (long <= edge) return w to h
        val scale = edge.toDouble() / long
        return (w * scale).roundToInt().coerceAtLeast(1) to (h * scale).roundToInt().coerceAtLeast(1)
    }

    /**
     * A small transparent image as PNG; otherwise JPEG at [QUALITY], once more at [RETRY_QUALITY]
     * when that is over [MAX_BYTES], and nothing when the retry is still over.
     */
    fun encode(hasAlpha: Boolean, png: () -> ByteArray, jpeg: (quality: Int) -> ByteArray): ByteArray? {
        if (hasAlpha) png().takeIf { it.size <= SMALL_PNG }?.let { return it }
        return jpeg(QUALITY).takeIf { it.size <= MAX_BYTES }
            ?: jpeg(RETRY_QUALITY).takeIf { it.size <= MAX_BYTES }
    }

    /** Tells a new picture from the same one posted again: a digest of the scaled pixels. */
    fun fingerprint(kind: String, width: Int, pixels: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update("$kind:$width:".toByteArray())
        return digest.digest(pixels).joinToString("") { "%02x".format(it) }
    }

    /**
     * Per notification key, the picture the Mac already has. A text-only update or an identical
     * re-post finds the same fingerprint and sends no picture. Not thread-safe: the relay thread owns it.
     */
    class Sent {
        private val last = HashMap<String, String>()

        /** True when [fingerprint] differs from what [key] last sent; records it either way. */
        fun isNew(key: String, fingerprint: String): Boolean = last.put(key, fingerprint) != fingerprint

        fun forget(key: String) {
            last.remove(key)
        }
    }
}
