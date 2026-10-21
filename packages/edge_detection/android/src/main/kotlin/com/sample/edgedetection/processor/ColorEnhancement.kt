package com.sample.edgedetection.processor

import org.opencv.core.*
import org.opencv.imgproc.Imgproc
import java.io.Closeable
import kotlin.math.*

/** A crop-specific, small paper-illumination map. Owned by the editor's serial worker. */
class EnhancementProfile internal constructor(
    internal val background: Mat?, internal val contrast: Double,
    internal val protectedContent: Mat? = null,
) : Closeable {
    override fun close() { background?.release(); protectedContent?.release() }
}

/** Document illumination correction in sRGB, shared numerically with ScanColorEnhancement.swift. */
object ColorEnhancement {
    const val ANALYSIS_EDGE = 768

    fun analyze(cropped: Mat): EnhancementProfile {
        val small = Mat(); val fine = Mat(); val coarse = Mat()
        val gray = Mat(); val narrowInk = Mat(); val wideInk = Mat()
        val scale = min(1.0, ANALYSIS_EDGE.toDouble() / max(cropped.cols(), cropped.rows()))
        val kernels = listOf(15, 31, 5).map { size ->
            val radius = max(1, (size * min(1.0, max(cropped.cols(), cropped.rows()) / 768.0)).roundToInt() / 2)
            Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(radius * 2.0 + 1, radius * 2.0 + 1))
        }
        try {
            Imgproc.resize(cropped, small, Size(max(2.0, (cropped.cols() * scale).roundToInt().toDouble()), max(2.0, (cropped.rows() * scale).roundToInt().toDouble())), 0.0, 0.0, Imgproc.INTER_AREA)
            Imgproc.morphologyEx(small, fine, Imgproc.MORPH_CLOSE, kernels[0], Point(-1.0, -1.0), 1, Core.BORDER_REPLICATE)
            Imgproc.morphologyEx(small, coarse, Imgproc.MORPH_CLOSE, kernels[1], Point(-1.0, -1.0), 1, Core.BORDER_REPLICATE)
            val w = small.cols(); val h = small.rows(); val count = w * h
            val pixels = ByteArray(count * 4); val paper = ByteArray(count * 4); val broad = ByteArray(count * 4)
            small.get(0, 0, pixels); fine.get(0, 0, paper); coarse.get(0, 0, broad)
            val histograms = Array(3) { IntArray(256) }
            val brightness = IntArray(256)
            for (i in 0 until count) {
                // Closing spreads cubic-resampling overshoot around letters. Its upper
                // percentile is not a reliable paper white point; sample the source instead.
                for (c in 0..2) histograms[c][u(pixels[i * 4 + c])]++
                brightness[(0..2).sumOf { u(broad[i * 4 + it]) } / 3]++
            }
            val reference = IntArray(3) { percentile(histograms[it], count, 0.9) }
            val referenceMean = reference.average()
            // Uniform dark/strongly colored images provide no trustworthy paper reference.
            if (referenceMean < 90 || (reference.maxOrNull()!! - reference.minOrNull()!!) / referenceMean > 0.35) return EnhancementProfile(null, 1.08)
            val varying = percentile(brightness, count, 0.9) - percentile(brightness, count, 0.1) > 6
            val invalid = BooleanArray(count)
            val content = BooleanArray(count)
            for (i in 0 until count) {
                var low = 10.0; var high = 0.0; var difference = 0
                var colorLow = 10.0; var colorHigh = 0.0; var colorTotal = 0.0
                for (c in 0..2) {
                    val ratio = u(paper[i * 4 + c]).toDouble() / max(1, reference[c])
                    low = min(low, ratio); high = max(high, ratio)
                    difference = max(difference, u(broad[i * 4 + c]) - u(paper[i * 4 + c]))
                    val color = u(broad[i * 4 + c]).toDouble() / max(1, reference[c])
                    colorLow = min(colorLow, color); colorHigh = max(colorHigh, color); colorTotal += color
                }
                invalid[i] = high - low > 0.12 || difference > 18
                // Strong, broad color is printed content even in deep shade. Normalize
                // chroma by local brightness; modest lighting casts remain paper.
                content[i] = (colorHigh - colorLow) / max(0.01, colorTotal / 3) > 0.35
            }
            // Dense photographic texture is not paper. Text usually occupies much less of a tile.
            for (top in 0 until h step 16) for (left in 0 until w step 16) {
                var dark = 0; var edges = 0; var samples = 0
                for (y in top until min(h, top + 16)) for (x in left until min(w, left + 16)) {
                    val i = (y * w + x) * 4
                    if ((0..2).sumOf { u(pixels[i + it]) } < (0..2).sumOf { u(paper[i + it]) } * 0.78) dark++
                    if (x > 0 && (0..2).sumOf { abs(u(pixels[i + it]) - u(pixels[i - 4 + it])) } > 120) edges++
                    samples++
                }
                if (dark > samples * 0.4 && edges > samples * 0.45) for (y in top until min(h, top + 16)) for (x in left until min(w, left + 16)) {
                    invalid[y * w + x] = true; content[y * w + x] = true
                }
            }
            // Enclosed rectangular gray fills are ambiguous; borrow surrounding paper instead.
            protectPanels(paper, content, w, h, referenceMean)
            for (i in 0 until count) if (content[i]) invalid[i] = true
            if (invalid.count { it } > count * 0.45) return EnhancementProfile(null, 1.08)
            val protected = expandMask(content, w, h, 2)
            if (varying) {
                val luminance = ByteArray(count) { i -> ((u(pixels[i * 4]) + u(pixels[i * 4 + 1]) + u(pixels[i * 4 + 2]) + 1) / 3).toByte() }
                gray.create(h, w, CvType.CV_8UC1); gray.put(0, 0, luminance)
                Imgproc.morphologyEx(gray, narrowInk, Imgproc.MORPH_CLOSE, kernels[2], Point(-1.0, -1.0), 1, Core.BORDER_REPLICATE)
                Imgproc.morphologyEx(gray, wideInk, Imgproc.MORPH_CLOSE, kernels[0], Point(-1.0, -1.0), 1, Core.BORDER_REPLICATE)
                val narrow = ByteArray(count); val wide = ByteArray(count)
                narrowInk.get(0, 0, narrow); wideInk.get(0, 0, wide)
                val ink = BooleanArray(count) { i -> u(luminance[i]) < u(narrow[i]) * 0.97 || u(luminance[i]) < u(wide[i]) * 0.80 }
                // One pixel covers colored JPEG fringes. A larger exclusion can bridge
                // the space between lines and interpolate across a real shadow boundary.
                val missingPaper = expandMask(ink, w, h, 1)
                for (i in 0 until count) if (protected[i]) missingPaper[i] = true
                if (missingPaper.count { !it } < count * 0.05) return EnhancementProfile(null, 1.08)
                val clean = pixels.copyOf()
                fillPaper(clean, missingPaper, w, h)
                // Keep sampled RGB triplets together. Another channel-wise maximum here
                // invents blue paper near blue text, producing yellow correction halos.
                clean.copyInto(paper)
            } else for (i in 0 until count) for (c in 0..2) paper[i * 4 + c] = reference[c].toByte()

            val inkHistogram = IntArray(256); var inkCount = 0
            for (i in 0 until count) {
                var total = 0.0; var low = 255.0; var high = 0.0
                for (c in 0..2) {
                    // Measure ink relative to paper before the export gain limit. Otherwise
                    // very deep paper shadows are mistaken for gray ink and over-contrasted.
                    val channel = min(255.0, u(pixels[i * 4 + c]) * 255.0 / max(1.0, u(paper[i * 4 + c]).toDouble()))
                    total += channel; low = min(low, channel); high = max(high, channel)
                }
                val value = (total / 3).roundToInt()
                if (!invalid[i] && value in 20..190 && high - low < 40) { inkHistogram[value]++; inkCount++ }
                paper[i * 4 + 3] = 255.toByte()
            }
            val contrast = if (inkCount > count * 0.002) (207.0 / (255 - percentile(inkHistogram, inkCount, 0.1))).coerceIn(1.08, 1.6) else 1.08
            val map = Mat(h, w, CvType.CV_8UC4)
            map.put(0, 0, paper)
            // Median smoothing removes small map noise without blurring across sharp shadows.
            Imgproc.medianBlur(map, map, 3)
            val protection = if (protected.any { it }) Mat(h, w, CvType.CV_8UC1).apply {
                put(0, 0, ByteArray(count) { if (protected[it]) 255.toByte() else 0 })
            } else null
            return EnhancementProfile(map, contrast, protection)
        } finally { (listOf(small, fine, coarse, gray, narrowInk, wideInk) + kernels).forEach { it.release() } }
    }

    fun apply(image: Mat, profile: EnhancementProfile) {
        val map = profile.background
        if (map == null) { image.convertTo(image, -1, 1.08, -20.4); return }
        val field = Mat(); val working = Mat(); val transform = Mat(2, 3, CvType.CV_64F)
        val minimum = Mat(); val channel = Mat(); val factor = Mat(); val curve = Mat()
        val multiplier = Mat(); val protection = Mat()
        val sx = image.cols().toDouble() / map.cols(); val sy = image.rows().toDouble() / map.rows()
        try {
            // Bound temporary float storage even for a 4096-pixel export.
            for (top in 0 until image.rows() step 64) {
                val rows = min(64, image.rows() - top)
                val stripe = image.rowRange(top, top + rows)
                try {
                    transform.put(0, 0, sx, 0.0, (sx - 1) / 2, 0.0, sy, (sy - 1) / 2 - top)
                    Imgproc.warpAffine(map, field, transform, Size(image.cols().toDouble(), rows.toDouble()), Imgproc.INTER_LINEAR, Core.BORDER_REPLICATE)
                    field.convertTo(field, CvType.CV_32F)
                    Core.max(field, Scalar.all(63.75), field)
                    stripe.convertTo(working, CvType.CV_32F)
                    Core.divide(working, field, working, 255.0)
                    Core.min(working, Scalar.all(255.0), working)
                    // Smooth only the last ~6% below paper white. A shared RGB factor
                    // preserves ink hue; filled graphics bypass this paper-noise cleanup.
                    Core.extractChannel(working, minimum, 0)
                    for (c in 1..2) { Core.extractChannel(working, channel, c); Core.min(minimum, channel, minimum) }
                    minimum.convertTo(factor, -1, -1.0 / 12.75, (255.0 - 2.125) / 12.75)
                    Core.max(factor, Scalar.all(0.0), factor); Core.min(factor, Scalar.all(1.0), factor)
                    factor.convertTo(curve, -1, -2.0, 3.0)
                    Core.multiply(factor, factor, factor); Core.multiply(factor, curve, factor)
                    profile.protectedContent?.let {
                        Imgproc.warpAffine(it, protection, transform, Size(image.cols().toDouble(), rows.toDouble()), Imgproc.INTER_LINEAR, Core.BORDER_REPLICATE)
                        protection.convertTo(protection, CvType.CV_32F, 1.0 / 255)
                        Core.max(factor, protection, factor)
                    }
                    Core.merge(listOf(factor, factor, factor, factor), multiplier)
                    Core.subtract(working, Scalar.all(255.0), working)
                    Core.multiply(working, multiplier, working)
                    Core.add(working, Scalar.all(255.0), working)
                    working.convertTo(stripe, CvType.CV_8U, profile.contrast, 255.0 * (1.0 - profile.contrast))
                } finally { stripe.release() }
            }
        } finally { listOf(field, working, transform, minimum, channel, factor, curve, multiplier, protection).forEach { it.release() } }
    }

    private fun protectPanels(paper: ByteArray, invalid: BooleanArray, w: Int, h: Int, reference: Double) {
        val visited = BooleanArray(w * h); val queue = IntArray(w * h)
        for (start in visited.indices) {
            if (visited[start] || (0..2).sumOf { u(paper[start * 4 + it]) } >= reference * 3 * 0.97) continue
            var head = 0; var tail = 1; queue[0] = start; visited[start] = true
            var x0 = w; var y0 = h; var x1 = 0; var y1 = 0
            while (head < tail) {
                val i = queue[head++]; val x = i % w; val y = i / w
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for (direction in 0..3) {
                    val next = neighbor(i, direction, w, h)
                    if (next >= 0 && !visited[next] && (0..2).sumOf { u(paper[next * 4 + it]) } < reference * 3 * 0.97) { visited[next] = true; queue[tail++] = next }
                }
            }
            if (x0 > 1 && y0 > 1 && x1 < w - 2 && y1 < h - 2 && tail > w * h * 0.005 && tail < w * h * 0.4 && tail > (x1 - x0 + 1) * (y1 - y0 + 1) * 0.9) {
                for (j in 0 until tail) invalid[queue[j]] = true
            }
        }
    }

    private fun fillPaper(paper: ByteArray, invalid: BooleanArray, w: Int, h: Int) {
        val known = BooleanArray(w * h) { !invalid[it] }; val queue = IntArray(w * h)
        var head = 0; var tail = 0
        for (i in known.indices) if (known[i]) queue[tail++] = i
        while (head < tail) {
            val i = queue[head++]
            for (direction in 0..3) {
                val next = neighbor(i, direction, w, h)
                if (next >= 0 && !known[next]) {
                    for (c in 0..2) paper[next * 4 + c] = paper[i * 4 + c]
                    known[next] = true; queue[tail++] = next
                }
            }
        }
        // Relax the filled regions so gradients continue through graphics without seams.
        var current = paper.copyOf(); var next = paper.copyOf()
        repeat(12) {
            for (y in 1 until h - 1) for (x in 1 until w - 1) {
                val i = y * w + x
                if (invalid[i]) for (c in 0..2) next[i * 4 + c] = ((u(current[(i - 1) * 4 + c]) + u(current[(i + 1) * 4 + c]) + u(current[(i - w) * 4 + c]) + u(current[(i + w) * 4 + c]) + 2) / 4).toByte()
            }
            val swap = current; current = next; next = swap
        }
        current.copyInto(paper)
    }

    private fun expandMask(mask: BooleanArray, w: Int, h: Int, radius: Int): BooleanArray {
        val expanded = mask.copyOf()
        // Include antialiased graphic borders, which are not clean paper samples.
        for (i in mask.indices) if (mask[i]) {
            val x = i % w; val y = i / w
            for (yy in max(0, y - radius)..min(h - 1, y + radius)) for (xx in max(0, x - radius)..min(w - 1, x + radius)) expanded[yy * w + xx] = true
        }
        return expanded
    }

    private fun u(value: Byte) = value.toInt() and 255
    private fun neighbor(i: Int, direction: Int, w: Int, h: Int): Int = when (direction) {
        0 -> if (i % w > 0) i - 1 else -1
        1 -> if (i % w + 1 < w) i + 1 else -1
        2 -> if (i >= w) i - w else -1
        else -> if (i + w < w * h) i + w else -1
    }
    private fun percentile(histogram: IntArray, count: Int, fraction: Double): Int {
        val target = max(1, ceil(count * fraction).toInt()); var total = 0
        for (i in histogram.indices) { total += histogram[i]; if (total >= target) return i }
        return 255
    }
}
