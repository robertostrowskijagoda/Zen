package com.roj.zen

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The signers the Dart side compares (ApkSigners.kt): a rotated key is
 * told apart from an APK with several signers, so an update signed with a
 * new key that the old one vouched for is not taken for a stranger, and
 * several signers are never taken for a lineage.
 */
class ApkSignersTest {
    private val old = "aa".repeat(32)
    private val new = "bb".repeat(32)
    private val other = "cc".repeat(32)

    @Test
    fun aRotatedKeySignsWithItsLastCertificateAndKeepsItsHistory() {
        assertEquals(
            mapOf("signers" to listOf(new), "lineage" to listOf(old, new)),
            apkSignerReport(false, listOf(old, new), null),
        )
    }

    @Test
    fun aKeyThatNeverRotatedHasNoLineage() {
        assertEquals(
            mapOf("signers" to listOf(old), "lineage" to emptyList<String>()),
            apkSignerReport(false, listOf(old), null),
        )
    }

    @Test
    fun severalSignersAreNeverALineage() {
        assertEquals(
            mapOf("signers" to listOf(old, other), "lineage" to emptyList<String>()),
            apkSignerReport(true, listOf(old, other), listOf(old, other)),
        )
    }

    @Test
    fun anOlderAndroidGivesItsSignaturesOnly() {
        assertEquals(
            mapOf("signers" to listOf(old), "lineage" to emptyList<String>()),
            apkSignerReport(false, null, listOf(old)),
        )
        assertEquals(
            mapOf("signers" to emptyList<String>(), "lineage" to emptyList<String>()),
            apkSignerReport(false, null, null),
        )
    }
}
