package com.roj.zen

import org.junit.Assert.assertEquals
import org.junit.Test

/** How long an autofill request waits while a new login is typed (ZenAutofillBridge.kt). */
class ZenAutofillTimeoutTest {
    private val opened = 1_000_000L

    @Test
    fun typingANewLoginKeepsTheRequestUntilFiveMinutesAfterItOpened() {
        assertEquals(5 * 60_000L, autofillTimeoutAfter(opened, opened, holding = true))
        assertEquals(4 * 60_000L, autofillTimeoutAfter(opened, opened + 60_000L, holding = true))
    }

    @Test
    fun leavingTheFormGivesAMinuteToPickButNeverPastTheSameEnd() {
        assertEquals(60_000L, autofillTimeoutAfter(opened, opened + 30_000L, holding = false))
        assertEquals(20_000L, autofillTimeoutAfter(opened, opened + 280_000L, holding = false))
    }

    @Test
    fun pastTheEndItEndsAtOnce() {
        assertEquals(0L, autofillTimeoutAfter(opened, opened + 5 * 60_000L, holding = true))
        assertEquals(0L, autofillTimeoutAfter(opened, opened + 10 * 60_000L, holding = true))
        assertEquals(0L, autofillTimeoutAfter(opened, opened + 10 * 60_000L, holding = false))
    }
}
