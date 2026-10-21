package com.sample.edgedetection.processor

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.util.AtomicFile
import androidx.exifinterface.media.ExifInterface
import org.opencv.android.Utils
import org.opencv.core.*
import org.opencv.imgproc.Imgproc
import java.io.File
import kotlin.math.*

enum class ScanFilter { ORIGINAL, ENHANCED, GRAYSCALE, BLACK_WHITE }

object ScanImages {
    fun decode(file: File): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Cannot read this image" }
        val options = BitmapFactory.Options().apply { inSampleSize = 1 }
        while (max(bounds.outWidth, bounds.outHeight) / options.inSampleSize > 8192) options.inSampleSize *= 2
        var bitmap = BitmapFactory.decodeFile(file.path, options) ?: error("Cannot decode this image")
        val matrix = Matrix()
        when (ExifInterface(file).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.postRotate(90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.postRotate(270f); matrix.postScale(-1f, 1f) }
        }
        if (!matrix.isIdentity) {
            val upright = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            if (upright !== bitmap) bitmap.recycle()
            bitmap = upright
        }
        return resize(bitmap, 4096).also { if (it !== bitmap) bitmap.recycle() }
    }

    fun resize(source: Bitmap, maxEdge: Int): Bitmap {
        val scale = min(1.0, maxEdge.toDouble() / max(source.width, source.height))
        return if (scale == 1.0) source else Bitmap.createScaledBitmap(source,
            max(1, (source.width * scale).roundToInt()), max(1, (source.height * scale).roundToInt()), true)
    }

    fun prepareEnhancement(source: Bitmap, corners: List<ScanPoint>): EnhancementProfile {
        val cropped = render(source, corners, 0, ScanFilter.ORIGINAL, maxEdge = ColorEnhancement.ANALYSIS_EDGE)
        val mat = Mat()
        return try { Utils.bitmapToMat(cropped, mat); ColorEnhancement.analyze(mat) }
        finally { mat.release(); cropped.recycle() }
    }

    fun render(source: Bitmap, corners: List<ScanPoint>, turns: Int, filter: ScanFilter,
               reduceShadows: Boolean = true, profile: EnhancementProfile? = null, maxEdge: Int = 4096): Bitmap {
        require(ScanGeometry.isValid(corners)) { "Invalid crop" }
        val input = Mat(); val output = Mat()
        val src = MatOfPoint2f(*corners.map { Point(it.x * (source.width - 1), it.y * (source.height - 1)) }.toTypedArray())
        val p = src.toArray()
        val width = max(2, max(hypot(p[1].x - p[0].x, p[1].y - p[0].y), hypot(p[2].x - p[3].x, p[2].y - p[3].y)).roundToInt())
        val height = max(2, max(hypot(p[3].x - p[0].x, p[3].y - p[0].y), hypot(p[2].x - p[1].x, p[2].y - p[1].y)).roundToInt())
        val scale = min(1.0, maxEdge.coerceIn(2, 4096).toDouble() / max(width, height))
        val w = max(2, (width * scale).roundToInt()); val h = max(2, (height * scale).roundToInt())
        val dst = MatOfPoint2f(Point(0.0, 0.0), Point(w - 1.0, 0.0), Point(w - 1.0, h - 1.0), Point(0.0, h - 1.0))
        val transform = Imgproc.getPerspectiveTransform(src, dst)
        try {
            Utils.bitmapToMat(source, input)
            Imgproc.warpPerspective(input, output, transform, Size(w.toDouble(), h.toDouble()), Imgproc.INTER_CUBIC, Core.BORDER_REPLICATE)
            when (filter) {
                ScanFilter.ORIGINAL -> Unit
                ScanFilter.ENHANCED -> if (!reduceShadows) output.convertTo(output, -1, 1.08, -20.4)
                    else if (profile != null) ColorEnhancement.apply(output, profile)
                    else ColorEnhancement.analyze(output).use { ColorEnhancement.apply(output, it) }
                ScanFilter.GRAYSCALE, ScanFilter.BLACK_WHITE -> {
                    Imgproc.cvtColor(output, output, Imgproc.COLOR_RGBA2GRAY)
                    if (filter == ScanFilter.BLACK_WHITE && min(w, h) >= 3) {
                        val block = min(51, (min(w, h) / 32).coerceAtLeast(3)).let { if (it % 2 == 0) it + 1 else it }
                        Imgproc.adaptiveThreshold(output, output, 255.0, Imgproc.ADAPTIVE_THRESH_GAUSSIAN_C, Imgproc.THRESH_BINARY, block, 9.0)
                    }
                }
            }
            when ((turns % 4 + 4) % 4) {
                1 -> Core.rotate(output, output, Core.ROTATE_90_CLOCKWISE)
                2 -> Core.rotate(output, output, Core.ROTATE_180)
                3 -> Core.rotate(output, output, Core.ROTATE_90_COUNTERCLOCKWISE)
            }
            val bitmap = Bitmap.createBitmap(output.cols(), output.rows(), Bitmap.Config.ARGB_8888)
            Utils.matToBitmap(output, bitmap)
            return bitmap
        } finally { listOf(input, output, src, dst, transform).forEach { it.release() } }
    }

    fun save(bitmap: Bitmap, destination: File) {
        val atomic = AtomicFile(destination)
        val stream = atomic.startWrite()
        try {
            check(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, stream)) { "Could not encode scan" }
            atomic.finishWrite(stream)
        } catch (error: Throwable) { atomic.failWrite(stream); throw error }
    }
}
