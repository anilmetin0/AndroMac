package dev.andromac.feature

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.util.Base64
import android.util.Log
import dev.andromac.core.Link
import dev.andromac.core.Protocol
import java.io.ByteArrayOutputStream

/**
 * Sends app icons to the Mac, which shows them as a badge next to the notification.
 *
 * Energy: an icon goes out only when the Mac asks for it (`icon_request`), and the Mac
 * caches it on disk — once per package for its lifetime. Embedded in the notification
 * message it would have cost roughly 10 KB extra on every single notification.
 */
class IconProvider(private val context: Context) {

    fun sendIcon(pkg: String) {
        val png = renderPng(pkg) ?: return
        Link.send(Protocol.appIcon(pkg, Base64.encodeToString(png, Base64.NO_WRAP)))
    }

    private fun renderPng(pkg: String): ByteArray? = try {
        val drawable = context.packageManager.getApplicationIcon(pkg)
        val bitmap = drawable.toBitmap(SIZE)
        ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        }
    } catch (e: Exception) {
        Log.i(Link.TAG, "could not render the icon: $pkg (${e.message})")
        null
    }

    /** Adaptive icons are not BitmapDrawables; we normalize them all by drawing onto a canvas. */
    private fun Drawable.toBitmap(size: Int): Bitmap {
        (this as? BitmapDrawable)?.bitmap?.let { source ->
            if (!source.isRecycled) return Bitmap.createScaledBitmap(source, size, size, true)
        }
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).also { canvas ->
            setBounds(0, 0, size, size)
            draw(canvas)
        }
        return bitmap
    }

    private companion object {
        const val SIZE = 128        // more than enough for a macOS notification attachment
    }
}
