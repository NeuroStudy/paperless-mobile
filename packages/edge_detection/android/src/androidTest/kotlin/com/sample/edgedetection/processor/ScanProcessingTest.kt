package com.sample.edgedetection.processor

import android.graphics.*
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.exifinterface.media.ExifInterface
import org.junit.Assert.*
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Mat
import java.io.File
import kotlin.math.hypot

@RunWith(AndroidJUnit4::class)
class ScanProcessingTest {
    companion object {
        @JvmStatic @BeforeClass fun loadOpenCv() { check(OpenCVLoader.initDebug()) }
    }
    private fun photograph(points: List<PointF>, width: Int = 800, height: Int = 1000): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap); canvas.drawColor(Color.rgb(35, 45, 50))
        val path = Path().apply { moveTo(points[0].x, points[0].y); points.drop(1).forEach { lineTo(it.x, it.y) }; close() }
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(235, 232, 225) }
        canvas.drawPath(path, paint); canvas.save(); canvas.clipPath(path)
        paint.color = Color.DKGRAY; paint.textSize = 14f
        for (y in 140..850 step 28) canvas.drawText("Document text: invoice 1234, paid in full.", 145f, y.toFloat(), paint)
        canvas.restore(); return bitmap
    }
    private fun detect(bitmap: Bitmap): DocumentCandidate? {
        val input = Mat()
        return try { Utils.bitmapToMat(bitmap, input); detectDocument(input) } finally { input.release(); bitmap.recycle() }
    }
    @Test fun recognizesPerspectivePageWithoutLosingCorners() {
        val corners = listOf(PointF(120f, 90f), PointF(680f, 140f), PointF(730f, 920f), PointF(75f, 870f))
        val result = detect(photograph(corners))
        assertNotNull(result)
        corners.forEachIndexed { i, expected ->
            val actual = result!!.points[i]
            assertTrue("Corner $i should follow the paper boundary", hypot(actual.x * 800 - expected.x, actual.y * 1000 - expected.y) < 0.02 * hypot(800.0, 1000.0))
        }
    }
    @Test fun recognizesNarrowReceipt() {
        assertNotNull(detect(photograph(listOf(PointF(290f, 70f), PointF(470f, 80f), PointF(500f, 930f), PointF(280f, 910f)))))
    }
    @Test fun recognizesLandscapePage() {
        assertNotNull(detect(photograph(listOf(PointF(60f, 200f), PointF(750f, 220f), PointF(730f, 690f), PointF(80f, 670f)))))
    }
    @Test fun recognizesLowContrastPaper() {
        val bitmap = Bitmap.createBitmap(800, 1000, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap); canvas.drawColor(Color.rgb(205, 205, 205))
        canvas.drawRect(100f, 80f, 700f, 920f, Paint().apply { color = Color.rgb(225, 225, 225) })
        assertNotNull(detect(bitmap))
    }
    @Test fun recognizesPaperWithBroadShadowAndSurroundingClutter() {
        val corners = listOf(PointF(120f, 90f), PointF(680f, 140f), PointF(730f, 920f), PointF(75f, 870f))
        val bitmap = photograph(corners)
        val canvas = Canvas(bitmap)
        canvas.drawRect(0f, 0f, 800f, 1000f, Paint().apply {
            shader = LinearGradient(0f, 0f, 800f, 0f, Color.argb(100, 0, 0, 0), Color.TRANSPARENT, Shader.TileMode.CLAMP)
        })
        canvas.drawCircle(45f, 40f, 25f, Paint().apply { color = Color.WHITE })
        canvas.drawRect(755f, 300f, 790f, 700f, Paint().apply { color = Color.GRAY })
        assertNotNull(detect(bitmap))
    }
    @Test fun blankSceneIsNotADocument() {
        val bitmap = Bitmap.createBitmap(800, 1000, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.LTGRAY) }
        assertNull(detect(bitmap))
    }
    @Test fun roundObjectIsNotADocument() {
        val bitmap = Bitmap.createBitmap(800, 1000, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap); canvas.drawColor(Color.DKGRAY)
        canvas.drawCircle(400f, 500f, 280f, Paint().apply { color = Color.WHITE })
        assertNull(detect(bitmap))
    }
    @Test fun rotationAndFiltersPreserveTheUntouchedSource() {
        val source = Bitmap.createBitmap(200, 300, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(150, 80, 40)) }
        val before = source.getPixel(100, 100)
        for (filter in ScanFilter.values()) {
            val result = ScanImages.render(source, ScanGeometry.fullImage, 1, filter)
            assertTrue(result.width > result.height)
            if (filter == ScanFilter.GRAYSCALE) {
                val color = result.getPixel(result.width / 2, result.height / 2)
                assertEquals(Color.red(color), Color.green(color)); assertEquals(Color.red(color), Color.blue(color))
            }
            result.recycle()
        }
        assertEquals(before, source.getPixel(100, 100))
        source.recycle()
    }
    @Test fun saveProducesADecodableJpegAndReplacesAnExistingDestination() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File.createTempFile("scan-output-", ".jpeg", context.cacheDir)
        val source = Bitmap.createBitmap(100, 150, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.WHITE) }
        try {
            ScanImages.save(source, file)
            val decoded = BitmapFactory.decodeFile(file.path)
            assertNotNull(decoded); assertEquals(100, decoded.width); assertEquals(150, decoded.height)
            decoded.recycle()
            source.eraseColor(Color.BLACK); ScanImages.save(source, file)
            val replacement = BitmapFactory.decodeFile(file.path)
            assertTrue(Color.red(replacement.getPixel(50, 75)) < 5); replacement.recycle()
            assertFalse(File(file.path + ".bak").exists())
        } finally { source.recycle(); file.delete() }
    }
    @Test fun defaultEnhancementKeepsFaintMarksVisible() {
        val source = Bitmap.createBitmap(200, 200, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.WHITE) }
        Canvas(source).drawRect(50f, 50f, 150f, 150f, Paint().apply { color = Color.rgb(240, 240, 240) })
        val output = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED)
        try {
            assertTrue("Enhancement should retain the contrast of faint ink", Color.red(output.getPixel(100, 100)) <= 240)
        } finally { output.recycle(); source.recycle() }
    }
    @Test fun invalidCrossingCropFailsBeforeRendering() {
        val source = Bitmap.createBitmap(100, 100, Bitmap.Config.ARGB_8888)
        try {
            assertThrows(IllegalArgumentException::class.java) {
                ScanImages.render(source, listOf(ScanGeometry.fullImage[0], ScanGeometry.fullImage[2], ScanGeometry.fullImage[1], ScanGeometry.fullImage[3]), 0, ScanFilter.ORIGINAL)
            }
        } finally { source.recycle() }
    }
    @Test fun decodeHonorsExifRotationWithoutUpscaling() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File.createTempFile("scan-exif-", ".jpg", context.cacheDir)
        val source = Bitmap.createBitmap(120, 200, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.WHITE) }
        try {
            ScanImages.save(source, file)
            val exif = ExifInterface(file)
            exif.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString()); exif.saveAttributes()
            val output = ScanImages.decode(file)
            assertEquals(200, output.width); assertEquals(120, output.height); output.recycle()
        } finally { source.recycle(); file.delete() }
    }
}
