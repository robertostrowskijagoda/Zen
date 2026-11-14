package com.roj.zen

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The screen kept on for a ringing call and for a running one, apart (CallScreenKeepOn.kt). */
class CallScreenKeepOnTest {
    @Test
    fun theEndOfTheRingingLeavesTheCallsKeepOn() {
        val keepOn = CallScreenKeepOn()
        keepOn.ringing = true
        keepOn.call = true
        // Answered: the ringing window goes, the call goes on.
        keepOn.ringing = false
        assertTrue(keepOn.wanted)
        keepOn.call = false
        assertFalse(keepOn.wanted)
    }

    @Test
    fun eitherAloneKeepsTheScreenOn() {
        val keepOn = CallScreenKeepOn()
        assertFalse(keepOn.wanted)
        keepOn.ringing = true
        assertTrue(keepOn.wanted)
        keepOn.ringing = false
        keepOn.call = true
        assertTrue(keepOn.wanted)
    }
}
