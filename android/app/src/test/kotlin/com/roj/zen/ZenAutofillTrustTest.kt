package com.roj.zen

import java.security.MessageDigest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Whom the autofill believes (ZenAutofillTrust.kt): a page's address only
 * from a known browser signed with its maker's certificate, on Android 9+;
 * an app's certificates as the picker gets them.
 */
class ZenAutofillTrustTest {
    private val pie = 28
    private val oreo = 27

    private fun pin(packageName: String): ByteArray =
        sha256Fingerprint(autofillBrowsers.getValue(packageName).first())!!

    /** A phone where [installed] packages are signed with those certificates. */
    private fun phone(vararg installed: Pair<String, ByteArray>): SigningCertificateLookup =
        SigningCertificateLookup { packageName, sha256 ->
            installed.any { (p, c) -> p == packageName && c.contentEquals(sha256) }
        }

    private val someoneElse = ByteArray(32) { 7 }

    @Test
    fun theGenuineBrowserIsBelievedAboutThePage() {
        val chrome = phone("com.android.chrome" to pin("com.android.chrome"))
        val web = trustedWebOrigin("com.android.chrome", "bank.example.com", "https", chrome, pie)
        assertEquals("bank.example.com", web!!.domain)
        assertEquals("https", web.scheme)
        assertEquals(BrowserSignature.MAKER, browserSignature("com.android.chrome", chrome, pie))
        // No scheme reported: matched as http, never with https entries.
        val firefox = phone("org.mozilla.firefox" to pin("org.mozilla.firefox"))
        assertNull(trustedWebOrigin("org.mozilla.firefox", "example.com", null, firefox, pie)!!.scheme)
        // DuckDuckGo from Google Play and from F-Droid: each its own key.
        for (key in autofillBrowsers.getValue("com.duckduckgo.mobile.android")) {
            val ddg = phone("com.duckduckgo.mobile.android" to sha256Fingerprint(key)!!)
            assertNotNull(trustedWebOrigin("com.duckduckgo.mobile.android", "bank.pl", "https", ddg, pie))
        }
    }

    @Test
    fun aBrowsersNameWithAnotherCertificateIsFilledLikeAnyApp() {
        // An app from elsewhere under the name of a browser the phone lacks.
        for (name in listOf(
            "org.mozilla.fennec_fdroid",
            "us.spotco.fennec_dos",
            "org.ironfoxoss.ironfox",
            "com.android.chrome",
        )) {
            val fake = phone(name to someoneElse)
            assertNull(name, trustedWebOrigin(name, "bank.pl", "https", fake, pie))
            assertEquals(name, BrowserSignature.OTHER, browserSignature(name, fake, pie))
        }
        // Another browser's key does not do for this one.
        val firefoxKey = phone("com.android.chrome" to pin("org.mozilla.firefox"))
        assertNull(trustedWebOrigin("com.android.chrome", "bank.pl", "https", firefoxKey, pie))
        // A lookup that fails believes nothing.
        val broken = SigningCertificateLookup { _, _ -> throw SecurityException("hidden") }
        assertNull(trustedWebOrigin("com.android.chrome", "bank.pl", "https", broken, pie))
    }

    @Test
    fun anAppZenDoesNotKnowOrABrowserWithoutAConfirmedKeyIsNeverBelieved() {
        val anything = SigningCertificateLookup { _, _ -> true }
        assertNull(trustedWebOrigin("com.evil.app", "bank.example.com", "https", anything, pie))
        assertEquals(BrowserSignature.UNCONFIRMED, browserSignature("com.evil.app", anything, pie))
        for (name in listOf("com.kiwibrowser.browser", "org.chromium.chrome", "com.sec.android.app.sbrowser")) {
            assertTrue(name, autofillBrowsers.getValue(name).isEmpty())
            assertNull(name, trustedWebOrigin(name, "bank.pl", "https", anything, pie))
            assertEquals(name, BrowserSignature.UNCONFIRMED, browserSignature(name, anything, pie))
        }
    }

    @Test
    fun beforeAndroid9NoBrowserIsBelieved() {
        val chrome = phone("com.android.chrome" to pin("com.android.chrome"))
        assertNull(trustedWebOrigin("com.android.chrome", "bank.pl", "https", chrome, oreo))
        assertEquals(BrowserSignature.UNCONFIRMED, browserSignature("com.android.chrome", chrome, oreo))
    }

    @Test
    fun onlyAPlausibleHostOfAWebPageCounts() {
        val chrome = phone("com.android.chrome" to pin("com.android.chrome"))
        assertNull(trustedWebOrigin("com.android.chrome", "a b", "https", chrome, pie))
        assertNull(trustedWebOrigin("com.android.chrome", "", "https", chrome, pie))
        assertNull(trustedWebOrigin("com.android.chrome", null, "https", chrome, pie))
        assertNull(trustedWebOrigin("com.android.chrome", "evil.com/@bank.pl", "https", chrome, pie))
        assertNull(trustedWebOrigin("com.android.chrome", "example.com", "file", chrome, pie))
    }

    @Test
    fun everyFingerprintIsOneAndEachBrowserIsListedOnce() {
        for ((name, keys) in autofillBrowsers) {
            for (key in keys) {
                assertNotNull("$name $key", sha256Fingerprint(key))
            }
            assertEquals(name, keys.size, keys.distinct().size)
        }
        assertNull(sha256Fingerprint("F0:FD"))
        assertNull(sha256Fingerprint("ZZ" + ":00".repeat(31)))
        assertArrayEquals(ByteArray(32) { 0xAB.toByte() }, sha256Fingerprint(List(32) { "AB" }.joinToString(":")))
    }

    @Test
    fun theSetupNamesEachSignature() {
        assertEquals("maker", setupSignature(BrowserSignature.MAKER))
        assertEquals("other", setupSignature(BrowserSignature.OTHER))
        assertEquals("unconfirmed", setupSignature(BrowserSignature.UNCONFIRMED))
    }

    private fun hex(algorithm: String, bytes: ByteArray): String =
        MessageDigest.getInstance(algorithm).digest(bytes).joinToString("") { "%02x".format(it) }

    @Test
    fun anAppsCertificatesAreEveryDigestOfItsLineageAndTheCurrentOne() {
        val old = "old certificate".toByteArray()
        val now = "current certificate".toByteArray()
        val signing = appSigning(listOf(old, now), multipleSigners = false)!!
        assertEquals(
            listOf(hex("SHA-256", old), hex("SHA-512", old), hex("SHA-256", now), hex("SHA-512", now)),
            signing.digests,
        )
        assertEquals(hex("SHA-512", now), signing.current)
        assertEquals(128, signing.current!!.length)
        // Several signers at once: none is the one to name.
        assertNull(appSigning(listOf(old, now), multipleSigners = true)!!.current)
        assertNull(appSigning(emptyList(), multipleSigners = false))
    }
}
