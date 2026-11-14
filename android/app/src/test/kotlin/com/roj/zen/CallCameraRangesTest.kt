package com.roj.zen

import org.junit.Assert.assertEquals
import org.junit.Test

/** A camera's frame-rate ranges as frames a second, whatever unit it reports in (ZenCallCamera.kt). */
class CallCameraRangesTest {
    @Test
    fun aCameraReportingFramesASecondKeepsItsNumbers() {
        // Camera2Session's fpsUnitFactor is 1000 for such a camera.
        assertEquals(Pair(24, 24), CallCameraRanges.toFps(24, 24, 1000))
        assertEquals(Pair(7, 30), CallCameraRanges.toFps(7, 30, 1000))
    }

    @Test
    fun aCameraReportingThousandthsIsReadInFramesASecond() {
        assertEquals(Pair(15, 30), CallCameraRanges.toFps(15000, 30000, 1))
        assertEquals(Pair(24, 24), CallCameraRanges.toFps(24000, 24000, 1))
    }
}
