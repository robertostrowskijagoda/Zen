package com.roj.zen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The power-button alarm shortcut's counting (ZenAlarmShortcut.kt). */
class PowerPressCounterTest {
    @Test
    fun fivePressesWithinTheWindowStartTheAlarm() {
        val counter = PowerPressCounter(presses = 5, windowMs = 4_000, cooldownMs = 30_000)
        val results = (0 until 5).map { counter.onToggle(1_000L + it * 500) }
        assertEquals(listOf(false, false, false, false, true), results)
    }

    @Test
    fun pressesSpreadOverMoreThanTheWindowDoNot() {
        val counter = PowerPressCounter(presses = 5, windowMs = 4_000, cooldownMs = 30_000)
        for (i in 0 until 10) {
            assertFalse(counter.onToggle(i * 1_100L))
        }
    }

    @Test
    fun pressingOnStartsOneAlarmNotTwo() {
        val counter = PowerPressCounter(presses = 5, windowMs = 4_000, cooldownMs = 30_000)
        val fired = (0 until 12).count { counter.onToggle(it * 300L) }
        assertEquals(1, fired)
        // After the cooldown the shortcut works again.
        val later = (0 until 5).map { counter.onToggle(60_000L + it * 300) }
        assertTrue(later.last())
    }
}
