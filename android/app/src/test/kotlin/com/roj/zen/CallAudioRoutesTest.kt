package com.roj.zen

import android.media.AudioDeviceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Where a call's sound goes, as ZenCallAudioRoute.kt tells the app. */
class CallAudioRoutesTest {
    @Test
    fun theCommunicationDeviceNamesTheRoute() {
        assertEquals("earpiece", CallAudioRoutes.ofDeviceType(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE))
        assertEquals("speaker", CallAudioRoutes.ofDeviceType(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
        assertEquals("wired", CallAudioRoutes.ofDeviceType(AudioDeviceInfo.TYPE_WIRED_HEADSET))
        assertEquals("wired", CallAudioRoutes.ofDeviceType(AudioDeviceInfo.TYPE_WIRED_HEADPHONES))
        assertEquals("wired", CallAudioRoutes.ofDeviceType(AudioDeviceInfo.TYPE_USB_HEADSET))
        assertEquals("bluetooth", CallAudioRoutes.ofDeviceType(AudioDeviceInfo.TYPE_BLUETOOTH_SCO))
        assertEquals("bluetooth", CallAudioRoutes.ofDeviceType(AudioDeviceInfo.TYPE_BLE_HEADSET))
        assertEquals("bluetooth", CallAudioRoutes.ofDeviceType(AudioDeviceInfo.TYPE_HEARING_AID))
    }

    @Test
    fun aDeviceThatIsNoCallRouteSaysNothing() {
        assertNull(CallAudioRoutes.ofDeviceType(AudioDeviceInfo.TYPE_HDMI))
        assertNull(CallAudioRoutes.ofDeviceType(AudioDeviceInfo.TYPE_UNKNOWN))
    }

    @Test
    fun belowAndroid12TheSwitchesNameIt() {
        assertEquals("earpiece", CallAudioRoutes.ofSwitches(false, false, false))
        // A headset plugged in takes the call from the earpiece.
        assertEquals("wired", CallAudioRoutes.ofSwitches(false, false, true))
        // The loudspeaker chosen stays even with a headset plugged.
        assertEquals("speaker", CallAudioRoutes.ofSwitches(false, true, true))
        // A Bluetooth link up carries the call whatever else is there.
        assertEquals("bluetooth", CallAudioRoutes.ofSwitches(true, true, true))
        assertEquals("bluetooth", CallAudioRoutes.ofSwitches(true, false, false))
    }
}
