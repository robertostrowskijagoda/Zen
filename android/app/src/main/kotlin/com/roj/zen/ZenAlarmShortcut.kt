package com.roj.zen

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.os.Build
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Counting for the power-button alarm shortcut, without any Android
 * dependency. Every press of the power button turns the screen on or off, so
 * [presses] such changes within [windowMs] mean the button was pressed that
 * many times on purpose. After a shortcut nothing counts for [cooldownMs], so
 * pressing on (10 times, say) starts one alarm, not two.
 */
class PowerPressCounter(
    private val presses: Int = 5,
    private val windowMs: Long = 4_000,
    private val cooldownMs: Long = 30_000,
) {
    private val times = ArrayList<Long>()
    private var lastShortcutMs: Long? = null

    /** A screen change at [nowMs]; `true` when it completes the shortcut. */
    fun onToggle(nowMs: Long): Boolean {
        val last = lastShortcutMs
        if (last != null && nowMs - last < cooldownMs) {
            return false
        }
        times.add(nowMs)
        while (times.isNotEmpty() && nowMs - times[0] > windowMs) {
            times.removeAt(0)
        }
        if (times.size < presses) {
            return false
        }
        times.clear()
        lastShortcutMs = nowMs
        return true
    }
}

/**
 * The power-button alarm shortcut on `zen/alarm_shortcut`.
 *
 * Dart turns it on while the person allows it; a receiver for screen on/off
 * then counts presses for as long as the process lives (the foreground
 * service keeps it alive with the app closed). A completed shortcut vibrates
 * and goes to exactly one engine, so the alarm starts once: the background
 * service while it runs the network (the app is away), otherwise the app,
 * otherwise whichever engine still listens.
 */
object ZenAlarmShortcut {
    private const val TAG = "ZenAlarmShortcut"

    /** Long-short-long: "alarm sent", felt in a pocket. */
    private val PATTERN = longArrayOf(0, 450, 150, 450, 150, 900)

    /** One engine listening. Touched on the main thread only. */
    private class Client(val engine: FlutterEngine, val background: Boolean) {
        var sink: EventChannel.EventSink? = null

        /** The background service runs the network now (the app is away). */
        var nodeOwner = false
    }

    private val clients = ArrayList<Client>()
    private val counter = PowerPressCounter()
    private var receiver: BroadcastReceiver? = null

    fun register(engine: FlutterEngine, context: Context, background: Boolean) {
        val app = context.applicationContext
        clients.removeAll { it.engine === engine }
        val client = Client(engine, background)
        clients.add(client)
        val messenger = engine.dartExecutor.binaryMessenger
        EventChannel(messenger, "zen/alarm_shortcut/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    client.sink = sink
                }

                override fun onCancel(arguments: Any?) {
                    client.sink = null
                }
            },
        )
        MethodChannel(messenger, "zen/alarm_shortcut").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "setEnabled" -> {
                        setEnabled(app, call.arguments as? Boolean ?: false)
                        result.success(null)
                    }
                    "setNodeOwner" -> {
                        client.nodeOwner = call.arguments as? Boolean ?: false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                Log.w(TAG, "${call.method} failed", error)
                result.error("alarm_shortcut", error.message, null)
            }
        }
    }

    /** [engine] is going away. */
    fun unregister(engine: FlutterEngine) {
        clients.removeAll { it.engine === engine }
    }

    private fun setEnabled(context: Context, on: Boolean) {
        if (on == (receiver != null)) {
            return
        }
        if (!on) {
            val old = receiver
            receiver = null
            if (old != null) {
                try {
                    context.unregisterReceiver(old)
                } catch (_: Exception) {
                }
            }
            return
        }
        val screen = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                val action = intent?.action
                if (action != Intent.ACTION_SCREEN_ON && action != Intent.ACTION_SCREEN_OFF) {
                    return
                }
                if (counter.onToggle(SystemClock.elapsedRealtime())) {
                    fire(context)
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        }
        try {
            // Screen on/off are protected broadcasts: only the system can
            // send them, so marking the receiver exported lets nobody else in.
            ContextCompat.registerReceiver(context, screen, filter, ContextCompat.RECEIVER_EXPORTED)
            receiver = screen
        } catch (error: Exception) {
            Log.w(TAG, "Registering the screen receiver failed", error)
        }
    }

    /** The shortcut is complete: one engine raises the alarm. */
    private fun fire(context: Context) {
        val target = clients.firstOrNull { it.background && it.nodeOwner && it.sink != null }
            ?: clients.lastOrNull { !it.background && it.sink != null }
            ?: clients.firstOrNull { it.sink != null }
        if (target == null) {
            Log.w(TAG, "Power-button alarm: no engine is listening")
            return
        }
        val sink = target.sink ?: return
        try {
            sink.success(mapOf("type" to "power", "at" to System.currentTimeMillis()))
        } catch (error: Exception) {
            Log.w(TAG, "Power-button alarm could not be delivered", error)
            return
        }
        Log.i(TAG, "Power-button alarm sent to the ${if (target.background) "service" else "app"}")
        vibrate(context)
    }

    @Suppress("DEPRECATION")
    private fun vibrator(context: Context): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }

    /**
     * Feedback that the alarm went out. Alarm usage, so it is felt with the
     * app in the background and in "do not disturb" too.
     */
    @Suppress("DEPRECATION")
    private fun vibrate(context: Context) {
        try {
            val vibrator = vibrator(context) ?: return
            if (!vibrator.hasVibrator()) {
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val attributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                vibrator.vibrate(VibrationEffect.createWaveform(PATTERN, -1), attributes)
            } else {
                vibrator.vibrate(PATTERN, -1)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Vibration failed", error)
        }
    }
}
