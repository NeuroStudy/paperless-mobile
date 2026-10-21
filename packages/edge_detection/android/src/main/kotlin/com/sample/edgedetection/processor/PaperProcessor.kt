package com.sample.edgedetection.processor

import org.opencv.core.*
import org.opencv.imgproc.Imgproc
import kotlin.math.*

/** Caller owns [input]. All working Mats, including rejected contours, are released here. */
fun detectDocument(input: Mat, previous: List<ScanPoint>? = null, maxEdge: Int = 960): DocumentCandidate? {
    val gray = Mat(); val edges = Mat(); val mask = Mat(); val closed = Mat()
    val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(3.0, 3.0))
    val contours = ArrayList<MatOfPoint>(); val hierarchy = Mat()
    try {
        if (input.channels() == 1) input.copyTo(gray) else
            Imgproc.cvtColor(input, gray, Imgproc.COLOR_RGBA2GRAY)
        val scale = min(1.0, maxEdge.toDouble() / max(gray.cols(), gray.rows()))
        if (scale < 1.0) Imgproc.resize(gray, gray, Size(), scale, scale, Imgproc.INTER_AREA)
        Imgproc.GaussianBlur(gray, gray, Size(5.0, 5.0), 0.0)
        Imgproc.threshold(gray, mask, 0.0, 255.0, Imgproc.THRESH_BINARY + Imgproc.THRESH_OTSU)
        val threshold = gradientThreshold(gray)
        Imgproc.Canny(gray, edges, max(8.0, threshold * 0.4), threshold)
        val edgePixels = ByteArray(edges.rows() * edges.cols())
        edges.get(0, 0, edgePixels)
        var best: DocumentCandidate? = null
        // Complementary proposals: actual edges and light/dark paper separation.
        for (proposal in listOf(edges, mask)) {
            Imgproc.morphologyEx(proposal, closed, Imgproc.MORPH_CLOSE, kernel)
            Imgproc.findContours(closed, contours, hierarchy, Imgproc.RETR_LIST, Imgproc.CHAIN_APPROX_SIMPLE)
            for (contour in contours.sortedByDescending { Imgproc.contourArea(it) }.take(30)) {
                val relativeArea = Imgproc.contourArea(contour) / gray.total()
                if (relativeArea !in 0.06..0.97) continue
                val curve = MatOfPoint2f(*contour.toArray()); val approx = MatOfPoint2f()
                try {
                    val perimeter = Imgproc.arcLength(curve, true)
                    for (epsilon in listOf(0.015, 0.025, 0.04)) {
                        Imgproc.approxPolyDP(curve, approx, perimeter * epsilon, true)
                        val raw = approx.toArray()
                        if (raw.size != 4) continue
                        val centerX = raw.sumOf { it.x } / 4; val centerY = raw.sumOf { it.y } / 4
                        val ordered = raw.sortedBy { atan2(it.y - centerY, it.x - centerX) }
                        val start = ordered.indices.minByOrNull { ordered[it].x + ordered[it].y }!!
                        val points = (0..3).map { ordered[(start + it) % 4] }.map {
                            ScanPoint((it.x / (gray.cols() - 1)).coerceIn(0.0, 1.0),
                                (it.y / (gray.rows() - 1)).coerceIn(0.0, 1.0))
                        }
                        if (!ScanGeometry.isValid(points)) continue
                        // Image borders are not a detected document.
                        if (points.count { it.x < 0.005 || it.y < 0.005 || it.x > 0.995 || it.y > 0.995 } > 2) continue
                        val pixelPoints = points.map { Point(it.x * (gray.cols() - 1), it.y * (gray.rows() - 1)) }
                        val support = boundarySupport(edgePixels, edges.cols(), edges.rows(), pixelPoints)
                        if (support < 0.35) continue
                        val quadArea = ScanGeometry.area(points)
                        val rectangularity = min(relativeArea, quadArea) / max(relativeArea, quadArea)
                        val agreement = previous?.let { max(0.0, 1.0 - ScanGeometry.distance(it, points) / 0.15) } ?: 0.5
                        val score = support * 0.50 + rectangularity * 0.20 + sqrt(quadArea) * 0.20 + agreement * 0.10
                        if (score > (best?.confidence ?: 0.52)) best = DocumentCandidate(points, score)
                    }
                } finally { curve.release(); approx.release() }
            }
            contours.forEach { it.release() }; contours.clear()
        }
        return best
    } finally {
        contours.forEach { it.release() }
        listOf(gray, edges, mask, closed, kernel, hierarchy).forEach { it.release() }
    }
}

/** Threshold the gradient distribution, not page brightness: pale edges still matter. */
private fun gradientThreshold(gray: Mat): Double {
    val dx = Mat(); val dy = Mat(); val absX = Mat(); val absY = Mat()
    try {
        Imgproc.Sobel(gray, dx, CvType.CV_16S, 1, 0)
        Imgproc.Sobel(gray, dy, CvType.CV_16S, 0, 1)
        Core.convertScaleAbs(dx, absX); Core.convertScaleAbs(dy, absY)
        val x = ByteArray(gray.rows() * gray.cols()); val y = ByteArray(x.size)
        absX.get(0, 0, x); absY.get(0, 0, y)
        val histogram = IntArray(256)
        for (index in x.indices) histogram[min(255, (x[index].toInt() and 255) + (y[index].toInt() and 255))]++
        val target = (x.size * 0.85).toInt(); var count = 0
        for (value in histogram.indices) {
            count += histogram[value]
            if (count >= target) return (value * 1.5).coerceIn(24.0, 160.0)
        }
        return 80.0
    } finally { listOf(dx, dy, absX, absY).forEach { it.release() } }
}

private fun boundarySupport(edges: ByteArray, width: Int, height: Int, points: List<Point>): Double {
    var hits = 0; var count = 0
    for (side in 0..3) {
        val a = points[side]; val b = points[(side + 1) % 4]
        for (step in 1..32) {
            val t = step / 33.0
            val x = (a.x + (b.x - a.x) * t).roundToInt()
            val y = (a.y + (b.y - a.y) * t).roundToInt()
            var found = false
            search@ for (dy in -3..3) for (dx in -3..3) {
                if (y + dy in 0 until height && x + dx in 0 until width &&
                    edges[(y + dy) * width + x + dx].toInt() != 0) { found = true; break@search }
            }
            if (found) hits++
            count++
        }
    }
    return hits.toDouble() / count
}
