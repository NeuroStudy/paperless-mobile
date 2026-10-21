package com.sample.edgedetection.processor

import kotlin.math.abs
import kotlin.math.hypot

/** Coordinates are relative to the upright image, never to a stretched view. */
data class ScanPoint(val x: Double, val y: Double)

object ScanGeometry {
    val fullImage = listOf(ScanPoint(0.0, 0.0), ScanPoint(1.0, 0.0),
        ScanPoint(1.0, 1.0), ScanPoint(0.0, 1.0))

    fun area(points: List<ScanPoint>): Double = if (points.size != 4) 0.0 else
        abs(points.indices.sumOf { i ->
            val next = points[(i + 1) % 4]
            points[i].x * next.y - next.x * points[i].y
        }) / 2.0

    fun isValid(points: List<ScanPoint>): Boolean {
        if (points.size != 4 || points.any { !it.x.isFinite() || !it.y.isFinite() ||
                    it.x !in 0.0..1.0 || it.y !in 0.0..1.0 } || area(points) < 0.005) return false
        return points.indices.all { i ->
            val a = points[i]; val b = points[(i + 1) % 4]; val c = points[(i + 2) % 4]
            hypot(a.x - b.x, a.y - b.y) > 0.01 &&
                (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 0.00001
        }
    }

    fun distance(a: List<ScanPoint>, b: List<ScanPoint>): Double =
        if (a.size != 4 || b.size != 4) Double.POSITIVE_INFINITY else
            a.indices.maxOf { hypot(a[it].x - b[it].x, a[it].y - b[it].y) }
}

data class DocumentCandidate(val points: List<ScanPoint>, val confidence: Double)

/** A time based tracker remains consistent when analysis frames are dropped. */
class DocumentTracker {
    var points: List<ScanPoint>? = null
        private set
    var stable = false
        private set
    private var anchor: List<ScanPoint>? = null
    private var stableSince = 0L
    private var lastSeen = 0L

    fun reset() {
        points = null; anchor = null; stable = false; stableSince = 0L; lastSeen = 0L
    }

    fun update(candidate: DocumentCandidate?, now: Long): List<ScanPoint>? {
        if (candidate == null || candidate.confidence < 0.52 || !ScanGeometry.isValid(candidate.points)) {
            if (now - lastSeen > 250) reset()
            return if (stable) null else points
        }
        if (lastSeen > 0 && now - lastSeen > 300) reset()
        lastSeen = now
        val detected = candidate.points
        val old = points
        if (anchor == null || ScanGeometry.distance(anchor!!, detected) > 0.015) {
            anchor = detected; stableSince = now; stable = false
        }
        points = if (old == null || ScanGeometry.distance(old, detected) > 0.12) detected else
            detected.indices.map { ScanPoint(old[it].x * 0.55 + detected[it].x * 0.45,
                old[it].y * 0.55 + detected[it].y * 0.45) }
        stable = now - stableSince >= 700
        return if (stable) null else points
    }
}
