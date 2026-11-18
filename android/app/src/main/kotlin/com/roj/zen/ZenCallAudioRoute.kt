package com.roj.zen

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.Executor

/**
 * Where a running call's sound goes, told to the app as soon as it changes
 * (call_audio_route.dart, `onCallAudioRoute`).
 *
 * The app knew the route only from its own choices ("Głośnik", the start of
 * the call). A headset plugged in or out, or a Bluetooth headset coming or
 * going, moves the sound by itself (the call's audio switch prefers a
 * headset and falls back to the earpiece), and the app went on believing
 * the earlier route until the call's next change: the proximity sensor
 * stayed held with the phone on the table and a headset on, or the screen
 * stayed lit at the ear once the headset was out.
 *
 * Watched only while a call decides the screen (from `setCallScreenMode`
 * other than `normal` until `normal`). It listens, it never polls: the
 * communication device itself on Android 12 and later, the audio devices
 * coming and going (Android 6 and later), and below Android 12 the
 * headset-plug and Bluetooth SCO broadcasts. Each of them only asks for a
 * look a moment later ([SETTLE_MS], so the audio switch has moved the
 * sound first); a look that finds the route as it was says nothing.
 */
object ZenCallAudioRoute {
    private const val TAG = "ZenCallAudioRoute"

    /** How long after a change the route is read: the audio switch reacts to the same events. */
    private const val SETTLE_MS = 300L

    private val handler = Handler(Looper.getMainLooper())
    private var audio: AudioManager? = null
    private var deviceCallback: AudioDeviceCallback? = null
    private var deviceListener: Any? = null
    private var receiver: BroadcastReceiver? = null
    private var appContext: Context? = null
    private var lastRoute: String? = null
    private var report: ((String) -> Unit)? = null

    private val look = Runnable { lookNow() }

    /** Starts ([on]) or stops watching the route; [onChange] gets each new one. Main thread. */
    fun watch(context: Context, on: Boolean, onChange: (String) -> Unit) {
        if (!on) {
            stop()
            return
        }
        report = onChange
        if (audio != null) {
            return
        }
        val app = context.applicationContext
        val manager = app.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        appContext = app
        audio = manager
        // What it is now is no news: only a change is told.
        lastRoute = readRoute(manager)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val listener = AudioManager.OnCommunicationDeviceChangedListener { changed() }
                manager.addOnCommunicationDeviceChangedListener(Executor { handler.post(it) }, listener)
                deviceListener = listener
            } else {
                val plug = object : BroadcastReceiver() {
                    override fun onReceive(context: Context?, intent: Intent?) = changed()
                }
                val filter = IntentFilter().apply {
                    addAction(Intent.ACTION_HEADSET_PLUG)
                    addAction(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)
                }
                // Protected broadcasts: only the system sends them.
                ContextCompat.registerReceiver(app, plug, filter, ContextCompat.RECEIVER_EXPORTED)
                receiver = plug
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val callback = object : AudioDeviceCallback() {
                    override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) = changed()
                    override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) = changed()
                }
                manager.registerAudioDeviceCallback(callback, handler)
                deviceCallback = callback
            }
        } catch (error: Exception) {
            Log.w(TAG, "Watching the call's audio route failed", error)
        }
    }

    private fun stop() {
        handler.removeCallbacks(look)
        val manager = audio
        try {
            if (manager != null) {
                deviceCallback?.let { manager.unregisterAudioDeviceCallback(it) }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    (deviceListener as? AudioManager.OnCommunicationDeviceChangedListener)?.let {
                        manager.removeOnCommunicationDeviceChangedListener(it)
                    }
                }
            }
            receiver?.let { appContext?.unregisterReceiver(it) }
        } catch (error: Exception) {
            Log.w(TAG, "Leaving the call's audio route failed", error)
        }
        deviceCallback = null
        deviceListener = null
        receiver = null
        audio = null
        appContext = null
        lastRoute = null
        report = null
    }

    private fun changed() {
        handler.removeCallbacks(look)
        handler.postDelayed(look, SETTLE_MS)
    }

    private fun lookNow() {
        val manager = audio ?: return
        val route = readRoute(manager) ?: return
        if (route == lastRoute) {
            return
        }
        lastRoute = route
        report?.invoke(route)
    }

    /** The route now: the communication device on Android 12 and later, else the legacy switches. */
    @Suppress("DEPRECATION")
    private fun readRoute(manager: AudioManager): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val device = manager.communicationDevice
            if (device != null) {
                return CallAudioRoutes.ofDeviceType(device.type)
            }
        }
        return CallAudioRoutes.ofSwitches(
            bluetoothSco = manager.isBluetoothScoOn,
            speakerphone = manager.isSpeakerphoneOn,
            wiredHeadset = manager.isWiredHeadsetOn,
        )
    }
}

/** A call's audio route by name, kept apart from Android for tests. */
object CallAudioRoutes {
    const val BLUETOOTH = "bluetooth"
    const val WIRED = "wired"
    const val SPEAKER = "speaker"
    const val EARPIECE = "earpiece"

    /** The route of a communication device of [type] (`AudioDeviceInfo.TYPE_…`), null for any other. */
    fun ofDeviceType(type: Int): String? = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_HEARING_AID,
        -> BLUETOOTH
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        -> WIRED
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE,
        -> SPEAKER
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> EARPIECE
        else -> null
    }

    /**
     * The route below Android 12, from the audio manager's switches: a
     * Bluetooth SCO link carries the call when it is up, the loudspeaker
     * when it is on, else a plugged headset takes it from the earpiece.
     */
    fun ofSwitches(bluetoothSco: Boolean, speakerphone: Boolean, wiredHeadset: Boolean): String =
        when {
            bluetoothSco -> BLUETOOTH
            speakerphone -> SPEAKER
            wiredHeadset -> WIRED
            else -> EARPIECE
        }
}
