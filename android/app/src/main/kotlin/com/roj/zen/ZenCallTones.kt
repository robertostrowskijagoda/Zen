package com.roj.zen

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector

/**
 * The tones of a call heard by this side only (call_tones.dart), on the
 * call's audio: the voice-call stream, at the call's volume and on its
 * route (earpiece, loudspeaker, headset), which the ringer's silent and
 * vibrate modes never mute. The ringback, busy and reconnecting tones are
 * the phone's own call tones (ToneGenerator, in the phone's country's
 * cadence); the connected and ended chimes are Zen's sounds, played with
 * the voice-communication usage. The in-app effects used the media stream
 * and were skipped altogether while the phone was on silent.
 */
object ZenCallTones {
    private const val TAG = "ZenCallTones"
    private const val VOLUME = 80

    /** A ringback nobody stopped ends by itself after this. */
    private const val RINGBACK_MAX_MS = 120_000L
    private const val BUSY_MS = 3_000

    private val handler = Handler(Looper.getMainLooper())
    private var tone: ToneGenerator? = null
    private var player: MediaPlayer? = null

    /** Starts [name] (a `CallTone` name), [asset] for Zen's chimes. Stops the one before. */
    fun play(context: Context, name: String, asset: String?): Boolean {
        stop()
        return try {
            when (name) {
                "ringback" -> tone(ToneGenerator.TONE_SUP_RINGTONE, -1)
                "busy" -> tone(ToneGenerator.TONE_SUP_BUSY, BUSY_MS)
                "reconnecting" -> tone(ToneGenerator.TONE_PROP_BEEP2, 600)
                else -> if (asset != null) chime(context, asset) else false
            }
        } catch (error: Exception) {
            Log.w(TAG, "Call tone $name failed", error)
            stop()
            false
        }
    }

    fun stop() {
        tone?.let {
            try {
                it.stopTone()
            } catch (_: Exception) {
            }
            it.release()
        }
        tone = null
        player?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        player = null
    }

    private fun tone(type: Int, durationMs: Int): Boolean {
        val generator = ToneGenerator(AudioManager.STREAM_VOICE_CALL, VOLUME)
        tone = generator
        val started = generator.startTone(type, durationMs)
        val releaseAfter = if (durationMs < 0) RINGBACK_MAX_MS else durationMs + 300L
        handler.postDelayed({ if (tone === generator) stop() }, releaseAfter)
        return started
    }

    private fun chime(context: Context, asset: String): Boolean {
        val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(asset)
        val media = MediaPlayer()
        try {
            media.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            context.assets.openFd(key).use { fd ->
                media.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
            }
            media.setOnCompletionListener {
                if (player === it) {
                    stop()
                } else {
                    it.release()
                }
            }
            media.prepare()
            media.start()
        } catch (error: Exception) {
            media.release()
            throw error
        }
        player = media
        return true
    }
}
