package com.roj.zen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Inexact alarms asked for so that their window ends when they are due (InexactAlarmWindow.kt). */
class InexactAlarmWindowTest {
    /** Where Android 12+ delivers an alarm asked for in [asked] at the latest. */
    private fun windowEnd(asked: Long): Long =
        if (asked < InexactAlarmWindow.NO_WINDOW_UNDER_MS) asked else asked + (asked * 0.75).toLong()

    @Test
    fun theNearbyTokensChangeComesByTheSlotsBoundaryWithoutExactAlarms() {
        // A token change asked for 10 minutes and half a second ahead.
        val due = 10 * 60_000L + 500
        val asked = InexactAlarmWindow.delayEndingIn(due)
        assertTrue(asked < due)
        assertTrue(windowEnd(asked) in due..due + 2)
        // Asked as before, it came up to 7.5 minutes late.
        assertEquals(due + (due * 0.75).toLong(), windowEnd(due))
    }

    @Test
    fun everyDelayComesByItsTimeAtTheLatest() {
        for (due in longArrayOf(17_500L, 60_000L, 5 * 60_000L, 2 * 60 * 60_000L)) {
            val asked = InexactAlarmWindow.delayEndingIn(due)
            assertTrue("$due: ${windowEnd(asked)}", windowEnd(asked) in due..due + 2)
        }
    }

    @Test
    fun shortDelaysGetNoWindowAndAreAskedForAsTheyAre() {
        // Under 17.5 s no window could end there: asked as it is (on time
        // under 10 s, at most 3/4 late above), never seconds early.
        for (due in longArrayOf(0L, 1_000L, 9_999L, 10_000L, 17_000L)) {
            assertEquals(due, InexactAlarmWindow.delayEndingIn(due))
        }
        assertEquals(0L, InexactAlarmWindow.delayEndingIn(-5L))
    }
}
