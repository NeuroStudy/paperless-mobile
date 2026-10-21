package com.sample.edgedetection.processor

import org.junit.Assert.*
import org.junit.Test

class ScanGeometryTest {
    private val page = listOf(ScanPoint(.2, .1), ScanPoint(.8, .15), ScanPoint(.85, .9), ScanPoint(.15, .85))

    @Test fun `perspective pages and narrow receipts are valid`() {
        assertTrue(ScanGeometry.isValid(page))
        assertTrue(ScanGeometry.isValid(listOf(ScanPoint(.4, .05), ScanPoint(.55, .05), ScanPoint(.55, .95), ScanPoint(.4, .95))))
        assertTrue(ScanGeometry.isValid(ScanGeometry.fullImage))
    }
    @Test fun `crossing concave duplicate and out of bounds corners are rejected`() {
        assertFalse(ScanGeometry.isValid(listOf(page[0], page[2], page[1], page[3])))
        assertFalse(ScanGeometry.isValid(listOf(page[0], page[1], ScanPoint(.3, .2), page[3])))
        assertFalse(ScanGeometry.isValid(listOf(page[0], page[1], page[1], page[3])))
        assertFalse(ScanGeometry.isValid(page.toMutableList().apply { this[0] = ScanPoint(-.1, .1) }))
    }
    @Test fun `alignment dots disappear after sustained stability and reappear after movement`() {
        val tracker = DocumentTracker()
        assertNotNull(tracker.update(DocumentCandidate(page, .9), 1000))
        for (time in 1125L..1625L step 125) assertNotNull(tracker.update(DocumentCandidate(page, .9), time))
        assertNull(tracker.update(DocumentCandidate(page, .9), 1700))
        assertTrue(tracker.stable)
        val shifted = page.map { ScanPoint(it.x + .04, it.y) }
        assertNotNull(tracker.update(DocumentCandidate(shifted, .9), 1800))
        assertFalse(tracker.stable)
    }
    @Test fun `loss clears stale corners and requires a fresh stability interval`() {
        val tracker = DocumentTracker()
        tracker.update(DocumentCandidate(page, .9), 1000)
        for (time in 1125L..1875L step 125) tracker.update(DocumentCandidate(page, .9), time)
        assertNull(tracker.update(null, 2200))
        assertNull(tracker.points)
        assertNotNull(tracker.update(DocumentCandidate(page, .9), 2300))
        assertFalse(tracker.stable)
    }
    @Test fun `low confidence never creates an overlay`() {
        assertNull(DocumentTracker().update(DocumentCandidate(page, .3), 1000))
    }
    @Test fun `resuming after a gap requires fresh observations`() {
        val tracker = DocumentTracker()
        for (time in 1000L..1875L step 125) tracker.update(DocumentCandidate(page, .9), time)
        assertTrue(tracker.stable)
        assertNotNull(tracker.update(DocumentCandidate(page, .9), 10000))
        assertFalse(tracker.stable)
    }
    @Test fun `slow drift cannot accumulate into stable recognition`() {
        val tracker = DocumentTracker()
        for (step in 0..12) {
            tracker.update(DocumentCandidate(page.map { ScanPoint(it.x + step * .004, it.y) }, .9), 1000L + step * 125)
            assertFalse(tracker.stable)
        }
    }
}
