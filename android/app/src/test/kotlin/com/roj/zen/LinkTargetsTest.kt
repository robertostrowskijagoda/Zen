package com.roj.zen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Where a link Zen claims goes (LinkTargets.kt): never back to Zen. Until
 * 1.15.5 every link went to Android's browser selector, which on some
 * phones listed every app calling itself a browser and never Discord or
 * GitHub.
 */
class LinkTargetsTest {
    private val own = "com.roj.zen"
    private val browsers = setOf("com.android.chrome", "org.mozilla.firefox")

    @Test
    fun theAppMadeForTheSiteWins() {
        assertEquals(
            "com.github.android",
            linkTargetWithoutZen(
                own,
                listOf(own, "com.android.chrome", "com.github.android"),
                browsers,
                "com.android.chrome",
            ),
        )
    }

    @Test
    fun elseTheDefaultBrowser() {
        assertEquals(
            "org.mozilla.firefox",
            linkTargetWithoutZen(
                own,
                listOf(own, "com.android.chrome", "org.mozilla.firefox"),
                browsers,
                "org.mozilla.firefox",
            ),
        )
    }

    @Test
    fun neverZenNorThePickerWithoutAChoice() {
        // No default browser: Android's picker ("android") is no browser.
        assertNull(
            linkTargetWithoutZen(own, listOf(own, "com.android.chrome"), browsers, "android"),
        )
        assertNull(linkTargetWithoutZen(own, listOf(own), browsers, own))
    }
}
