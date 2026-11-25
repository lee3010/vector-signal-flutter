package com.vectorsignal.flutter

import android.graphics.Bitmap
import android.os.Build
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * Compresses an already-masked session-replay frame to WebP with Android's own encoder:
 * about 5x smaller than the PNG Flutter can make, the same format big apps use.
 * Input is RGBA bytes (Flutter's rawRgba); frames are opaque app screens.
 */
object ReplayImageEncoder {
    fun encodeWebp(rgba: ByteArray, width: Int, height: Int, quality: Int): ByteArray {
        require(width > 0 && height > 0 && rgba.size == width * height * 4) { "Bad frame size" }
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            // ARGB_8888 is stored as R, G, B, A bytes: the same order as rawRgba.
            bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
            val out = ByteArrayOutputStream(rgba.size / 20)
            @Suppress("DEPRECATION")
            val format = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Bitmap.CompressFormat.WEBP_LOSSY
            } else {
                Bitmap.CompressFormat.WEBP
            }
            bitmap.compress(format, quality.coerceIn(1, 100), out)
            return out.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }
}
