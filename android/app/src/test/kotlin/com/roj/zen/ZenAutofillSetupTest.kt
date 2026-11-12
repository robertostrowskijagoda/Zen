package com.roj.zen

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The browsers' side of the password manager's setup
 * (ZenAutofillSetupBridge.kt): only package names are looked at, and a
 * browser's switch is on or off only for the two values Chrome documents.
 */
class ZenAutofillSetupTest {
    @Test
    fun onlyPackageNamesAreLookedAtEachOnce() {
        assertEquals(
            listOf("com.android.chrome", "com.brave.browser"),
            setupBrowserPackages(
                listOf(
                    "com.android.chrome",
                    "com.android.chrome",
                    "chrome",
                    "com.android.chrome/../x",
                    "com.brave.browser",
                    "content://evil",
                    "",
                    7,
                    null,
                ),
            ),
        )
        assertEquals(emptyList<String>(), setupBrowserPackages(null))
        assertEquals(emptyList<String>(), setupBrowserPackages("com.android.chrome"))
        assertEquals(emptyList<String>(), setupBrowserPackages(listOf("a." + "b".repeat(300))))
    }

    @Test
    fun atMostFortyBrowsersAreLookedAt() {
        val many = (1..100).map { "com.example.browser$it" }
        assertEquals(many.take(MAX_SETUP_BROWSERS), setupBrowserPackages(many))
    }

    @Test
    fun theSwitchIsOnOrOffOnlyForTheDocumentedValues() {
        assertEquals(BROWSER_SWITCH_OFF, thirdPartyModeState(0))
        assertEquals(BROWSER_SWITCH_ON, thirdPartyModeState(1))
        assertEquals(BROWSER_SWITCH_UNKNOWN, thirdPartyModeState(2))
        assertEquals(BROWSER_SWITCH_UNKNOWN, thirdPartyModeState(-1))
        assertEquals(BROWSER_SWITCH_UNKNOWN, thirdPartyModeState(null))
    }

    @Test
    fun theProviderIsTheBrowsersOwn() {
        assertEquals(
            "content://com.chrome.beta.AutofillThirdPartyModeContentProvider/autofill_third_party_mode",
            thirdPartyModeUri("com.chrome.beta"),
        )
    }
}
