package com.roj.zen

import android.content.Context
import android.os.PowerManager
import android.util.Log

/**
 * The proximity sensor during a voice call on the earpiece
 * (call_screen_awake.dart): while it is held, the screen goes dark and
 * ignores touches whenever the phone is at the ear, and lights up again
 * when it is moved away. Released when the call ends, goes to the
 * loudspeaker or a headset, or becomes a video call; then the screen is
 * let back on only once nothing is close any more, as the phone's own
 * dialler does.
 */
object ZenCallProximity {
    private const val TAG = "ZenCallProximity"

    /** A call longer than this lets the sensor go; the next change of the call takes it again. */
    private const val MAX_HOLD_MS = 4L * 60 * 60 * 1000

    private var lock: PowerManager.WakeLock? = null

    /** Holds ([on]) or releases the sensor. Whether the phone has it (true when released). */
    fun hold(context: Context, on: Boolean): Boolean {
        if (!on) {
            release()
            return true
        }
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        if (!power.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
            return false
        }
        val held = lock
        if (held != null && held.isHeld) {
            return true
        }
        return try {
            val fresh = power.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "zen:call_proximity")
            fresh.setReferenceCounted(false)
            fresh.acquire(MAX_HOLD_MS)
            lock = fresh
            true
        } catch (error: Exception) {
            Log.w(TAG, "Holding the proximity sensor failed", error)
            false
        }
    }

    private fun release() {
        val held = lock ?: return
        lock = null
        try {
            if (held.isHeld) {
                held.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Releasing the proximity sensor failed", error)
        }
    }
}
