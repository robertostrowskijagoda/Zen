package com.roj.zen

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

/**
 * The ring of an incoming call, as a phone call rings: the phone's own
 * ringtone over and over at the ringer's volume, and a repeating
 * vibration, as the ringer mode allows (silent: nothing, vibrate: only the
 * vibration). A notification's sound plays once, quietly, at the
 * notification volume, and its vibration is whatever its channel was
 * created with: a call was easy to miss, above all on a locked phone.
 *
 * Started when a call starts ringing on this device ([start], also from
 * the locked background service), stopped when it is answered, declined
 * or ends ([stop]). One ring at a time, process-wide.
 */
object ZenRinger {
    private const val TAG = "ZenRinger"

    /** Long buzz, pause, long buzz, longer pause: repeated from index 0. */
    private val PATTERN = longArrayOf(0, 800, 400, 800, 1600)

    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null

    @Synchronized
    fun start(context: Context) {
        if (player != null || vibrator != null) {
            return
        }
        val app = context.applicationContext
        val audio = app.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val mode = audio?.ringerMode ?: AudioManager.RINGER_MODE_NORMAL
        if (mode == AudioManager.RINGER_MODE_SILENT) {
            return
        }
        if (mode == AudioManager.RINGER_MODE_NORMAL) {
            player = ringtone(app)
        }
        vibrator = vibrate(app)
    }

    @Synchronized
    fun stop() {
        player?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        player = null
        vibrator?.cancel()
        vibrator = null
    }

    private fun ringtone(context: Context): MediaPlayer? {
        val uri = RingtoneManager.getActualDefaultRingtoneUri(
            context,
            RingtoneManager.TYPE_RINGTONE,
        ) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        return try {
            MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(context, uri)
                isLooping = true
                prepare()
                start()
            }
        } catch (error: Exception) {
            Log.w(TAG, "The ringtone did not start", error)
            null
        }
    }

    private fun vibrate(context: Context): Vibrator? {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)
                ?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        if (vibrator == null || !vibrator.hasVibrator()) {
            return null
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val effect = VibrationEffect.createWaveform(PATTERN, 0)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    vibrator.vibrate(
                        effect,
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .build(),
                    )
                } else {
                    vibrator.vibrate(effect)
                }
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(PATTERN, 0)
            }
            vibrator
        } catch (error: Exception) {
            Log.w(TAG, "The vibration did not start", error)
            null
        }
    }
}
