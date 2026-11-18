package com.roj.zen

/**
 * The manufacturer data (company 0xFFFF) of a Bluetooth link advert, with
 * no Android dependency ([ZenBluetoothLinkBridge] sends and reads it).
 *
 * This side sends "ZG" and the bridge's advert (a 7-byte header and the
 * Bloom filter, local_link.go): nothing else. Until 1.18.0 it sent "ZL",
 * the L2CAP PSM and the advert. The advert's own fields change every slot
 * or every advert (slot, salt, filter) or are the same on every Zen device
 * (the version), but the PSM stayed for as long as the listener lived and
 * Android hands PSMs out in turn from 0x80: a number of the phone's own
 * that tied its adverts together across address changes and slots. The
 * PSM is now read over GATT (…0003), and only by a device that is going
 * to connect, that is one whose friend's tag the advert carried.
 *
 * "ZL" is still read: Linux computers send it (they have no GATT server;
 * their PSM is the first free one from 0x80, so it is the same on nearly
 * every one of them), and so do phones on 1.18.0 and older.
 */
object BluetoothLinkAdvert {
    /** "ZG": the advert alone, the PSM on GATT. */
    val MAGIC_GATT_PSM = byteArrayOf(0x5A, 0x47)

    /** "ZL": the PSM (uint16 little-endian), then the advert. */
    val MAGIC_WITH_PSM = byteArrayOf(0x5A, 0x4C)

    /** The smallest advert: a 7-byte header and an 8-byte filter. */
    const val MIN_ADVERT = 7 + 8

    /** What a scan saw: the advert, and the PSM if the data carried one. */
    class Seen(val advert: ByteArray, val psm: Int, val psmOnGatt: Boolean)

    /** The manufacturer data that shows [advert]. */
    fun manufacturerData(advert: ByteArray): ByteArray = MAGIC_GATT_PSM + advert

    /** Reads Zen's manufacturer data [data]; `null` if it is not Zen's or too short. */
    fun parse(data: ByteArray?): Seen? {
        if (data == null || data.size < 2) {
            return null
        }
        return when {
            data[0] == MAGIC_GATT_PSM[0] && data[1] == MAGIC_GATT_PSM[1] ->
                if (data.size < 2 + MIN_ADVERT) {
                    null
                } else {
                    Seen(data.copyOfRange(2, data.size), 0, psmOnGatt = true)
                }
            data[0] == MAGIC_WITH_PSM[0] && data[1] == MAGIC_WITH_PSM[1] ->
                if (data.size < 4 + MIN_ADVERT) {
                    null
                } else {
                    Seen(
                        data.copyOfRange(4, data.size),
                        (data[2].toInt() and 0xFF) or ((data[3].toInt() and 0xFF) shl 8),
                        psmOnGatt = false,
                    )
                }
            else -> null
        }
    }
}
