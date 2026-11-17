package com.roj.zen

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

/**
 * The manufacturer data of a Bluetooth link advert (BluetoothLinkAdvert.kt).
 * Until 1.18.0 it carried the L2CAP PSM, which stays the same for as long
 * as the listener lives and differs from phone to phone: whoever listened
 * nearby could tie one phone's adverts together across address changes
 * and slots (audit finding L7).
 */
class BluetoothLinkAdvertTest {
    private val random = Random(7)

    /**
     * An advert as local_link.go makes it: version 2, the slot's low 16
     * bits, a random salt, then a 16-byte Bloom filter of the slot's tags.
     */
    private fun advert(slot: Int): ByteArray {
        val out = ByteArray(7 + 16)
        random.nextBytes(out)
        out[0] = 2
        out[1] = (slot shr 8).toByte()
        out[2] = slot.toByte()
        return out
    }

    /** The data a phone on 1.18.0 sent: "ZL", the PSM, the advert. */
    private fun oldData(psm: Int, advert: ByteArray): ByteArray =
        byteArrayOf(0x5A, 0x4C, psm.toByte(), (psm shr 8).toByte()) + advert

    /**
     * The byte positions that one device repeats in every capture but that
     * another device sends differently: what ties one device's adverts
     * together. Positions the same on every Zen device ("Z", the version)
     * say only "Zen", which the service UUID says anyway.
     */
    private fun linkingPositions(one: List<ByteArray>, other: List<ByteArray>): List<Int> {
        val size = one.minOf { it.size }
        return (0 until size).filter { i ->
            one.all { it[i] == one[0][i] } && other.any { it.size > i && it[i] != one[0][i] }
        }
    }

    @Test
    fun capturesFromDifferentSlotsShareNoFieldOfTheirOwn() {
        // One phone over a day of five-minute slots, and another one.
        val phone = (0 until 288).map { BluetoothLinkAdvert.manufacturerData(advert(5000 + it)) }
        val other = (0 until 288).map { BluetoothLinkAdvert.manufacturerData(advert(5000 + it)) }
        assertEquals(emptyList<Int>(), linkingPositions(phone, other))
        // Nothing but "ZG" and the advert: no room for a number of its own.
        for (data in phone) {
            assertEquals(2 + 7 + 16, data.size)
            assertArrayEquals(BluetoothLinkAdvert.MAGIC_GATT_PSM, data.copyOfRange(0, 2))
        }
    }

    @Test
    fun theOldDataTiedOnePhonesAdvertsTogetherByItsPsm() {
        // The same check finds the PSM in what 1.18.0 sent.
        val phone = (0 until 288).map { oldData(0x83, advert(5000 + it)) }
        val other = (0 until 288).map { oldData(0x81, advert(5000 + it)) }
        assertEquals(listOf(2), linkingPositions(phone, other))
    }

    @Test
    fun aFriendReadsTheAdvertAndKnowsToAskGattForThePsm() {
        val sent = advert(5000)
        val seen = BluetoothLinkAdvert.parse(BluetoothLinkAdvert.manufacturerData(sent))
        assertNotNull(seen)
        assertArrayEquals(sent, seen!!.advert)
        assertEquals(0, seen.psm)
        assertTrue(seen.psmOnGatt)
    }

    @Test
    fun linuxAndOldPhonesStillShowTheirPsm() {
        val sent = advert(5000)
        val seen = BluetoothLinkAdvert.parse(oldData(0x0080, sent))
        assertNotNull(seen)
        assertArrayEquals(sent, seen!!.advert)
        assertEquals(0x80, seen.psm)
        assertEquals(false, seen.psmOnGatt)
    }

    @Test
    fun notOursOrCutShortIsNothing() {
        assertNull(BluetoothLinkAdvert.parse(null))
        assertNull(BluetoothLinkAdvert.parse(ByteArray(0)))
        assertNull(BluetoothLinkAdvert.parse(byteArrayOf(0x5A)))
        assertNull(BluetoothLinkAdvert.parse(byteArrayOf(0x5A, 0x47)))
        assertNull(BluetoothLinkAdvert.parse(byteArrayOf(0x5A, 0x47) + ByteArray(14)))
        assertNull(BluetoothLinkAdvert.parse(byteArrayOf(0x5A, 0x4C) + ByteArray(16)))
        // People nearby ("ZN") are not links.
        assertNull(BluetoothLinkAdvert.parse(byteArrayOf(0x5A, 0x4E) + ByteArray(20)))
        assertNotNull(BluetoothLinkAdvert.parse(byteArrayOf(0x5A, 0x47) + ByteArray(15)))
        assertNotNull(BluetoothLinkAdvert.parse(byteArrayOf(0x5A, 0x4C) + ByteArray(17)))
    }

    @Test
    fun hostileDataNeverThrows() {
        val hostile = Random(11)
        repeat(20_000) {
            val data = ByteArray(hostile.nextInt(64))
            hostile.nextBytes(data)
            if (data.size >= 2 && hostile.nextBoolean()) {
                data[0] = 0x5A
                data[1] = if (hostile.nextBoolean()) 0x47 else 0x4C
            }
            val seen = BluetoothLinkAdvert.parse(data)
            if (seen != null) {
                assertTrue(seen.advert.size >= BluetoothLinkAdvert.MIN_ADVERT)
                assertTrue(seen.psm in 0..0xFFFF)
            }
        }
    }
}
