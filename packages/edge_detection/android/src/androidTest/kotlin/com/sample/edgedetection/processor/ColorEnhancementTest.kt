package com.sample.edgedetection.processor

import android.graphics.*
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import org.opencv.android.OpenCVLoader
import java.io.File
import java.io.ByteArrayOutputStream
import kotlin.math.*

@RunWith(AndroidJUnit4::class)
class ColorEnhancementTest {
    companion object { @JvmStatic @BeforeClass fun load() { check(OpenCVLoader.initDebug()) } }

    private fun page(): Bitmap {
        val image = Bitmap.createBitmap(600, 800, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(image); canvas.drawColor(Color.rgb(250, 248, 245))
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(35, 35, 35); textSize = 20f }
        for (y in 100..600 step 50) canvas.drawText("Readable document 0123456789", 60f, y.toFloat(), paint)
        paint.color = Color.rgb(40, 95, 170); canvas.drawText("Blue title", 60f, 60f, paint)
        paint.color = Color.rgb(210, 115, 35); canvas.drawText("Orange title", 300f, 60f, paint)
        paint.color = Color.rgb(195, 205, 225); paint.strokeWidth = 2f
        canvas.drawLine(300f, 690f, 400f, 725f, paint)
        return image
    }

    private fun shadow(source: Bitmap, loss: Double, hard: Boolean = false, warm: Boolean = false): Bitmap {
        val w = source.width; val h = source.height
        val pixels = IntArray(w * h); source.getPixels(pixels, 0, w, 0, 0, w, h)
        for (y in 0 until h) for (x in 0 until w) {
            val distance = x.toDouble() / w + 0.3 * y / h - 0.7
            val shade = if (hard) if (distance < 0) 1.0 else 0.0 else 1.0 / (1 + exp(distance * 15))
            val factor = 1 - loss * shade; val color = pixels[y * w + x]
            pixels[y * w + x] = Color.rgb((Color.red(color) * factor).roundToInt(),
                (Color.green(color) * factor * if (warm) 0.94 else 1.0).roundToInt(),
                (Color.blue(color) * factor * if (warm) 0.86 else 1.0).roundToInt())
        }
        return Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply { setPixels(pixels, 0, w, 0, 0, w, h) }
    }

    @Test fun removesDifferentGradesAndShapesOfShadowWithoutErasingInk() {
        val clean = page()
        try {
            for (loss in listOf(0.0, 0.05, 0.15, 0.35, 0.6, 0.8)) for (hard in listOf(false, true)) {
                val source = shadow(clean, loss, hard, warm = true)
                val result = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED)
                try {
                    val blank = listOf(30 to 150, 550 to 150, 30 to 740, 550 to 740).map { (x, y) -> luma(result.getPixel(x, y)) }
                    val spread = blank.maxOrNull()!! - blank.minOrNull()!!
                    if (loss <= 0.6) {
                        assertTrue("loss=$loss hard=$hard paper=$blank", blank.minOrNull()!! > 242)
                        assertTrue("loss=$loss hard=$hard spread=$spread", spread < 12)
                    } else assertTrue("Deep shadows should be improved with bounded gain: hard=$hard paper=$blank", blank.minOrNull()!! > 150)
                    assertTrue("Text should remain dark", darkest(result, 60, 185, 320, 200) < 90)
                    assertTrue("Faint blue signature should remain visible", darkest(result, 300, 685, 400, 730) < 230)
                } finally { source.recycle(); result.recycle() }
            }
        } finally { clean.recycle() }
    }

    @Test fun retainsPaleGrayFillAndColoredPanels() {
        val source = page(); val canvas = Canvas(source)
        canvas.drawRect(100f, 250f, 250f, 400f, Paint().apply { color = Color.rgb(240, 240, 240) })
        canvas.drawRect(350f, 250f, 500f, 400f, Paint().apply { color = Color.rgb(50, 100, 180) })
        canvas.drawRect(100f, 450f, 250f, 560f, Paint().apply { color = Color.rgb(160, 160, 160) })
        val output = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED)
        try {
            assertTrue(luma(output.getPixel(170, 320)) < 247)
            assertTrue(luma(output.getPixel(170, 500)) < 180)
            val blue = output.getPixel(420, 320)
            assertTrue(Color.blue(blue) - Color.red(blue) > 80)
            assertTrue(luma(blue) < 180)
        } finally { source.recycle(); output.recycle() }
    }

    @Test fun textureAndUniformDarkImagesUseConservativeCorrection() {
        for (textured in listOf(false, true)) {
            val source = Bitmap.createBitmap(240, 320, Bitmap.Config.ARGB_8888)
            val pixels = IntArray(240 * 320) { i ->
                val gray = if (!textured) 35 else if ((i % 240 + i / 240) % 4 < 2) 40 else 210
                Color.rgb(gray, gray, gray)
            }
            source.setPixels(pixels, 0, 240, 0, 0, 240, 320)
            val on = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED)
            val off = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED, reduceShadows = false)
            try { assertEquals(off.getPixel(120, 160), on.getPixel(120, 160)) }
            finally { source.recycle(); on.recycle(); off.recycle() }
        }
    }

    @Test fun cachedProfileAgreesAcrossPreviewExportRotationAndSwitching() {
        val clean = page(); val source = shadow(clean, 0.6); clean.recycle()
        val before = source.getPixel(50, 50)
        ScanImages.prepareEnhancement(source, ScanGeometry.fullImage).use { profile ->
            val full = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED, profile = profile)
            val preview = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED, profile = profile, maxEdge = 400)
            val rotated = ScanImages.render(source, ScanGeometry.fullImage, 1, ScanFilter.ENHANCED, profile = profile)
            val off = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED, reduceShadows = false, profile = profile)
            try {
                assertTrue(abs(luma(full.getPixel(30, 740)) - luma(preview.getPixel(15, 370))) < 4)
                assertEquals(full.getPixel(30, 740), rotated.getPixel(full.height - 1 - 740, 30))
                assertTrue(luma(full.getPixel(30, 740)) - luma(off.getPixel(30, 740)) > 50)
                assertEquals(before, source.getPixel(50, 50))
            } finally { listOf(full, preview, rotated, off).forEach { it.recycle() } }
        }
        source.recycle()
    }

    @Test fun overlappingCoolShadowsKeepColoredInk() {
        val clean = page()
        Canvas(clean).drawRect(340f, 400f, 420f, 460f, Paint().apply { color = Color.rgb(40, 95, 170) })
        val source = shadow(clean, 0.4)
        val pixels = IntArray(source.width * source.height)
        source.getPixels(pixels, 0, source.width, 0, 0, source.width, source.height)
        for (y in 0 until source.height) for (x in 0 until source.width) {
            val factor = 1 - 0.4 * y / source.height
            val i = y * source.width + x; val c = pixels[i]
            pixels[i] = Color.rgb((Color.red(c) * factor * 0.88).roundToInt(), (Color.green(c) * factor * 0.94).roundToInt(), (Color.blue(c) * factor).roundToInt())
        }
        source.setPixels(pixels, 0, source.width, 0, 0, source.width, source.height)
        val output = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED)
        val expected = ScanImages.render(clean, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED)
        try {
            assertTrue(luma(output.getPixel(30, 740)) > 240)
            val actualHue = FloatArray(3); val expectedHue = FloatArray(3)
            Color.colorToHSV(output.getPixel(380, 430), actualHue); Color.colorToHSV(expected.getPixel(380, 430), expectedHue)
            assertTrue("Blue ink hue should survive mixed shadows", abs(actualHue[0] - expectedHue[0]) < 12)
            assertTrue(actualHue[1] > 0.4)
        } finally { listOf(clean, source, output, expected).forEach { it.recycle() } }
    }

    @Test fun largeExportKeepsAnalysisBoundedAndRecordsTiming() {
        val small = page(); val large = Bitmap.createScaledBitmap(small, 2400, 3200, true); small.recycle()
        val source = shadow(large, 0.6); large.recycle()
        val start = SystemClock.elapsedRealtime()
        ScanImages.prepareEnhancement(source, ScanGeometry.fullImage).use { profile ->
            val analyzed = SystemClock.elapsedRealtime()
            assertTrue(profile.background!!.cols() <= 768 && profile.background.rows() <= 768)
            val output = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED, profile = profile)
            try { assertTrue(output.width > 2300); assertTrue(luma(output.getPixel(100, 3000)) > 240) }
            finally { output.recycle() }
            Log.i("ScannerEnhancement", "7.7MP analysis=${analyzed - start}ms cachedExport=${SystemClock.elapsedRealtime() - analyzed}ms")
            val peakRss = File("/proc/self/status").useLines { lines -> lines.firstOrNull { it.startsWith("VmHWM:") } }
            Log.i("ScannerEnhancement", "Process memory after 7.7MP export: $peakRss nativeAllocated=${android.os.Debug.getNativeHeapAllocatedSize() / 1024}KB")
        }
        source.recycle()
    }

    @Test fun compressedColoredTextDoesNotLeaveYellowPaperBetweenLines() {
        val clean = page(); val canvas = Canvas(clean)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(45, 100, 175); textSize = 18f }
        for (y in 240..420 step 24) canvas.drawText("Colored text and readable fine print", 60f, y.toFloat(), paint)
        val shaded = shadow(clean, 0.55, warm = true)
        val jpeg = ByteArrayOutputStream().also { shaded.compress(Bitmap.CompressFormat.JPEG, 78, it) }.toByteArray()
        val source = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size); shaded.recycle()
        val output = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED)
        try {
            var total = 0.0; var chroma = 0.0; var samples = 0
            val paperColor = Color.rgb(250, 248, 245)
            for (y in 220 until 445) for (x in 55 until 530) {
                // Select paper from the known clean fixture, never from the filter output.
                if ((-2..2).all { dy -> (-2..2).all { dx -> clean.getPixel(x + dx, y + dy) == paperColor } }) {
                    val color = output.getPixel(x, y)
                    total += luma(color)
                    val rgb = listOf(Color.red(color), Color.green(color), Color.blue(color))
                    chroma += rgb.maxOrNull()!! - rgb.minOrNull()!!; samples++
                }
            }
            assertTrue(samples > 10000)
            assertTrue("Paper brightness=${total / samples}", total / samples > 252)
            assertTrue("Residual paper chroma=${chroma / samples}", chroma / samples < 2)
            assertTrue("Colored ink remains legible", darkest(output, 60, 225, 400, 240) < 100)
            assertTrue("Faint signature survives cleanup", darkest(output, 300, 685, 400, 730) < 230)
        } finally { clean.recycle(); source.recycle(); output.recycle() }
    }

    @Test fun denseTypeAndColoredGraphicsDoNotErasePalePrintedFills() {
        val clean = page(); val canvas = Canvas(clean)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 22f; color = Color.rgb(40, 40, 40) }
        for (y in 150..410 step 28) canvas.drawText("Readable document 0123456789", 50f, y.toFloat(), paint)
        paint.textSize = 52f; paint.typeface = Typeface.DEFAULT_BOLD; paint.color = Color.rgb(45, 80, 150)
        canvas.drawText("Large TITLE", 45f, 70f, paint)
        paint.color = Color.rgb(240, 240, 240); canvas.drawRect(100f, 450f, 220f, 550f, paint)
        paint.color = Color.rgb(50, 100, 180); canvas.drawOval(440f, 450f, 540f, 550f, paint)
        val source = shadow(clean, 0.0, warm = true); clean.recycle()
        val output = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED)
        try {
            assertTrue("Pale panel is not paper noise", luma(output.getPixel(160, 500)) < 247)
            val blue = output.getPixel(490, 500)
            assertTrue(Color.blue(blue) - Color.red(blue) > 80)
            assertTrue(darkest(output, 45, 30, 400, 70) < 100)
        } finally { source.recycle(); output.recycle() }
    }

    /** Optional local reference supplied with -e scannerReference /data/local/tmp/example.jpg. Never bundled. */
    @Test fun suppliedReferenceWhenRequested() {
        val args = InstrumentationRegistry.getArguments()
        val path = args.getString("scannerReference")
        assumeTrue(path != null)
        require(path!!.matches(Regex("/data/local/tmp/[a-zA-Z0-9._-]+")))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bytes = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand("cat $path")).use { it.readBytes() }
        val screenshot = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        val source = Bitmap.createBitmap(screenshot, 198, 46, 795, 1167); screenshot.recycle()
        val start = SystemClock.elapsedRealtime()
        ScanImages.prepareEnhancement(source, ScanGeometry.fullImage).use { profile ->
            val analyzed = SystemClock.elapsedRealtime()
            val output = ScanImages.render(source, ScanGeometry.fullImage, 0, ScanFilter.ENHANCED, profile = profile)
            try {
                val folder = instrumentation.targetContext.getExternalFilesDir(null)!!
                ScanImages.save(output, File(folder, "reference-enhanced.jpg"))
                File(folder, "reference-enhanced.png").outputStream().use { output.compress(Bitmap.CompressFormat.PNG, 100, it) }
                profile.background?.let { map ->
                    val bitmap = Bitmap.createBitmap(map.cols(), map.rows(), Bitmap.Config.ARGB_8888)
                    org.opencv.android.Utils.matToBitmap(map, bitmap)
                    try { ScanImages.save(bitmap, File(folder, "reference-paper-map.jpg")) } finally { bitmap.recycle() }
                }
                val paper = listOf(700 to 80, 50 to 650, 370 to 1100).map { luma(output.getPixel(it.first, it.second)) }
                Log.i("ScannerEnhancement", "Reference paper=$paper contrast=${profile.contrast} analysis=${analyzed-start}ms render=${SystemClock.elapsedRealtime()-analyzed}ms output=$folder")
                assertTrue("Reference paper should be near white: $paper", paper.minOrNull()!! > 245)
                var sum = 0.0; var chroma = 0.0; var samples = 0
                // Fixed strips above/between the blue lines that previously turned yellow.
                for ((top, bottom) in listOf(462 to 474, 498 to 502, 523 to 526, 549 to 553)) {
                    for (y in top until bottom) for (x in 105 until 650) {
                        val color = output.getPixel(x, y)
                        val rgb = listOf(Color.red(color), Color.green(color), Color.blue(color))
                        sum += luma(color); chroma += rgb.maxOrNull()!! - rgb.minOrNull()!!; samples++
                    }
                }
                Log.i("ScannerEnhancement", "Reference line gaps: brightness=${sum / samples} chroma=${chroma / samples}")
                assertTrue("Line-gap paper stays white", sum / samples > 252)
                assertTrue("Line gaps should not turn yellow", chroma / samples < 2)
            } finally { output.recycle() }
        }
        source.recycle()
    }

    private fun darkest(image: Bitmap, x0: Int, y0: Int, x1: Int, y1: Int): Double {
        var value = 255.0
        for (y in y0 until y1) for (x in x0 until x1) value = min(value, luma(image.getPixel(x, y)))
        return value
    }
    private fun luma(color: Int) = (Color.red(color) + Color.green(color) + Color.blue(color)) / 3.0
}
