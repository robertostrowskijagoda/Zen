package com.roj.zen

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Zen and the phone's sleep, on `zen/power` and `zen/power/events`.
 *
 * The background service holds no wake lock of its own: with the screen off
 * the phone sleeps, and only what has to happen wakes it, each time for a
 * few seconds:
 *  - work that comes back (a look around nearby, asking the mailboxes for
 *    mail, the locked phone's outbox, the watchdog) is an alarm
 *    ([schedule]: `setAndAllowWhileIdle`, or `setExactAndAllowWhileIdle`
 *    where it must be on time and the person allowed exact alarms; a plain
 *    `set` that Doze puts off for work Doze would skip anyway) that wakes
 *    the phone and holds it awake for at most the alarm's window under the
 *    alarm's own tag, then tells the engines ("wake" with its id); Dart
 *    releases that tag as soon as the work is done;
 *  - a signal that arrives wakes the phone by itself; Dart holds it awake
 *    a few seconds more to handle it ([hold] with a time limit);
 *  - only a call holds the phone (and Wi-Fi) awake for as long as it runs
 *    ([holdForCall]).
 * Every hold has a time limit, so a mistake never keeps the phone awake.
 */
object ZenPower {
    private const val TAG = "ZenPower"
    private const val ACTION_WAKE = "com.roj.zen.WAKE"
    private const val WAKE_SCHEME = "zen-wake"
    private const val EXTRA_HOLD_MS = "holdMs"
    private const val EXTRA_TAG = "tag"

    /** No timed hold lasts longer than this. */
    private const val MAX_HOLD_MS = 2 * 60 * 60_000L

    /** A call's hold, renewed while the call runs (a safety limit). */
    private const val CALL_HOLD_MS = 6 * 60 * 60_000L

    /** How long the service may take to start a node once the app is gone. */
    private const val APP_GONE_HOLD_MS = 30_000L

    /** One engine listening. Touched on the main thread only. */
    private class Client(val engine: FlutterEngine, val background: Boolean) {
        var sink: EventChannel.EventSink? = null
    }

    private val clients = ArrayList<Client>()

    /** Timed holds by tag, and when each ends (elapsed realtime). */
    private val locks = HashMap<String, PowerManager.WakeLock>()
    private val holdUntil = HashMap<String, Long>()
    private var callWifiLock: WifiManager.WifiLock? = null
    private var receiver: BroadcastReceiver? = null

    /** Alarms handled here in Kotlin (the nearby token's change). */
    private val nativeAlarms = HashMap<String, () -> Unit>()

    fun register(engine: FlutterEngine, context: Context, background: Boolean) {
        val app = context.applicationContext
        clients.removeAll { it.engine === engine }
        val client = Client(engine, background)
        clients.add(client)
        val messenger = engine.dartExecutor.binaryMessenger
        EventChannel(messenger, "zen/power/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    client.sink = sink
                }

                override fun onCancel(arguments: Any?) {
                    client.sink = null
                }
            },
        )
        MethodChannel(messenger, "zen/power").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "hold" -> {
                        val tag = call.argument<String>("tag") ?: "work"
                        val ms = (call.argument<Number>("ms") ?: 0).toLong()
                        hold(app, tag, ms)
                        result.success(null)
                    }
                    "release" -> {
                        val tag = call.argument<String>("tag") ?: "work"
                        val after = (call.argument<Number>("afterMs") ?: 0).toLong()
                        if (after > 0) {
                            releaseAfter(tag, after)
                        } else {
                            release(tag)
                        }
                        result.success(null)
                    }
                    "schedule" -> {
                        val id = call.argument<String>("id")
                        if (id.isNullOrEmpty()) {
                            result.error("power", "no id", null)
                        } else {
                            schedule(
                                app,
                                id,
                                (call.argument<Number>("delayMs") ?: 0).toLong(),
                                call.argument<Boolean>("exact") ?: false,
                                (call.argument<Number>("holdMs") ?: 0).toLong(),
                                call.argument<String>("tag"),
                                call.argument<Boolean>("whileIdle") ?: true,
                            )
                            result.success(true)
                        }
                    }
                    "cancel" -> {
                        val id = call.argument<String>("id")
                        if (!id.isNullOrEmpty()) {
                            cancel(app, id)
                        }
                        result.success(null)
                    }
                    "holdForCall" -> {
                        holdForCall(app, call.arguments as? Boolean ?: false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                Log.w(TAG, "${call.method} failed", error)
                result.error("power", error.message, null)
            }
        }
    }

    /** [engine] is going away. */
    fun unregister(engine: FlutterEngine) {
        clients.removeAll { it.engine === engine }
    }

    /**
     * The app's engine is gone (swiped away, closed with "back", or ended by
     * Android): the background service takes the node over now instead of
     * waiting for the missing heartbeats, and the phone stays awake while
     * it does.
     */
    fun appEngineGone(context: Context) {
        val app = context.applicationContext
        hold(app, "app-gone", APP_GONE_HOLD_MS)
        for (client in clients.toList()) {
            if (!client.background) {
                continue
            }
            try {
                client.sink?.success(mapOf("type" to "appGone"))
            } catch (error: Exception) {
                Log.w(TAG, "Telling the service the app is gone failed", error)
            }
        }
    }

    /** Holds the phone awake for [ms] under [tag] (the longest hold wins). */
    fun hold(context: Context, tag: String, ms: Long) {
        if (ms <= 0) {
            return
        }
        val length = ms.coerceAtMost(if (tag == "call") CALL_HOLD_MS else MAX_HOLD_MS)
        val now = SystemClock.elapsedRealtime()
        val lock = lockFor(context, tag) ?: return
        val until = holdUntil[tag]
        if (lock.isHeld && until != null && until >= now + length) {
            return
        }
        try {
            // Not reference counted: a new acquire moves the time limit.
            lock.acquire(length)
            holdUntil[tag] = now + length
        } catch (error: Exception) {
            Log.w(TAG, "Holding the phone awake failed", error)
        }
    }

    fun release(tag: String) {
        holdUntil.remove(tag)
        val lock = locks[tag] ?: return
        try {
            if (lock.isHeld) {
                lock.release()
            }
        } catch (error: Exception) {
            Log.w(TAG, "Releasing a hold failed", error)
        }
    }

    /**
     * Ends [tag]'s hold in [ms] instead of at its old limit (the work is
     * done; what it set off gets a moment). Nothing when it is not held.
     */
    fun releaseAfter(tag: String, ms: Long) {
        val lock = locks[tag] ?: return
        try {
            if (!lock.isHeld) {
                holdUntil.remove(tag)
                return
            }
            val until = holdUntil[tag]
            val now = SystemClock.elapsedRealtime()
            if (until != null && until <= now + ms) {
                return
            }
            // Not reference counted: a new acquire replaces the time limit.
            lock.acquire(ms)
            holdUntil[tag] = now + ms
        } catch (error: Exception) {
            Log.w(TAG, "Shortening a hold failed", error)
        }
    }

    private fun lockFor(context: Context, tag: String): PowerManager.WakeLock? {
        locks[tag]?.let { return it }
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return null
        val lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "zen:$tag")
        lock.setReferenceCounted(false)
        locks[tag] = lock
        return lock
    }

    /**
     * A call holds the phone and Wi-Fi awake while it runs (the service
     * then also has the microphone/camera type).
     */
    @Suppress("DEPRECATION")
    fun holdForCall(context: Context, on: Boolean) {
        if (!on) {
            release("call")
            try {
                callWifiLock?.let { if (it.isHeld) it.release() }
            } catch (error: Exception) {
                Log.w(TAG, "Releasing the call's Wi-Fi lock failed", error)
            }
            callWifiLock = null
            return
        }
        hold(context, "call", CALL_HOLD_MS)
        if (callWifiLock?.isHeld == true) {
            return
        }
        try {
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            callWifiLock = wifi.createWifiLock(mode, "zen:call").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (error: Exception) {
            Log.w(TAG, "Holding Wi-Fi for the call failed", error)
        }
    }

    /**
     * Wakes the phone in [delayMs] and holds it awake for at most [holdMs]
     * under [tag] (Dart releases it once the work is done); then the engines
     * hear "wake" with [id]. A new schedule of the same id replaces the old
     * one. Not [whileIdle]: Doze puts it off to its next window.
     */
    fun schedule(
        context: Context,
        id: String,
        delayMs: Long,
        exact: Boolean,
        holdMs: Long,
        tag: String? = null,
        whileIdle: Boolean = true,
    ) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        ensureReceiver(context)
        val at = SystemClock.elapsedRealtime() + delayMs.coerceAtLeast(0)
        val pending = pendingIntent(context, id, holdMs, create = true, tag = tag) ?: return
        val canExact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            alarms.canScheduleExactAlarms()
        } else {
            true
        }
        if (!whileIdle) {
            // Work Doze would skip anyway (a look around): not worth a
            // wake in Doze, and batched with other alarms.
            alarms.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (exact && canExact) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending)
            } else {
                alarms.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending)
            }
        } else {
            alarms.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending)
        }
    }

    fun cancel(context: Context, id: String) {
        nativeAlarms.remove(id)
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val pending = pendingIntent(context, id, 0, create = false) ?: return
        alarms.cancel(pending)
        pending.cancel()
    }

    /** Like [schedule], but [task] runs here (main thread) instead of in Dart. */
    fun scheduleNative(
        context: Context,
        id: String,
        delayMs: Long,
        exact: Boolean,
        holdMs: Long,
        task: () -> Unit,
    ) {
        nativeAlarms[id] = task
        schedule(context, id, delayMs, exact, holdMs)
    }

    private fun pendingIntent(
        context: Context,
        id: String,
        holdMs: Long,
        create: Boolean,
        tag: String? = null,
    ): PendingIntent? {
        val intent = Intent(ACTION_WAKE)
            .setPackage(context.packageName)
            // The id in the data: two ids are two different alarms.
            .setData(Uri.fromParts(WAKE_SCHEME, id, null))
            .putExtra(EXTRA_HOLD_MS, holdMs)
        if (tag != null) {
            intent.putExtra(EXTRA_TAG, tag)
        }
        var flags = PendingIntent.FLAG_IMMUTABLE
        flags = flags or if (create) PendingIntent.FLAG_UPDATE_CURRENT else PendingIntent.FLAG_NO_CREATE
        return PendingIntent.getBroadcast(context, 0, intent, flags)
    }

    private fun ensureReceiver(context: Context) {
        if (receiver != null) {
            return
        }
        val wake = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                if (intent?.action != ACTION_WAKE) {
                    return
                }
                val id = intent.data?.schemeSpecificPart ?: return
                onWake(
                    context.applicationContext,
                    id,
                    intent.getLongExtra(EXTRA_HOLD_MS, 0),
                    intent.getStringExtra(EXTRA_TAG),
                )
            }
        }
        val filter = IntentFilter(ACTION_WAKE).apply { addDataScheme(WAKE_SCHEME) }
        try {
            ContextCompat.registerReceiver(
                context.applicationContext,
                wake,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            receiver = wake
        } catch (error: Exception) {
            Log.w(TAG, "Registering the wake receiver failed", error)
        }
    }

    private fun onWake(context: Context, id: String, holdMs: Long, tag: String?) {
        // First the hold: the phone may fall asleep again right after this.
        // Under the alarm's own tag, which Dart releases once its work is
        // done (one alarm's end never cuts another's work short).
        hold(context, tag ?: "wake", holdMs.coerceAtLeast(3_000))
        val native = nativeAlarms.remove(id)
        if (native != null) {
            try {
                native()
            } catch (error: Exception) {
                Log.w(TAG, "A wake task failed", error)
            }
            return
        }
        for (client in clients.toList()) {
            try {
                client.sink?.success(mapOf("type" to "wake", "id" to id))
            } catch (error: Exception) {
                Log.w(TAG, "A wake could not be delivered", error)
            }
        }
    }
}
