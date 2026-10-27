package com.roj.zen

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Where the phone is (`zen/location`), straight from the platform's
 * LocationManager: GPS and network providers, nothing else (no Google Play
 * services). location.dart drives it:
 *
 *  - `check` / `request`: "denied", "deniedForever", "whileInUse" or
 *    "always". `request` asks for the precise and approximate location only
 *    (the background one comes from the system settings, where the
 *    permissions screen sends the person); without an Activity (the
 *    background service) it only checks.
 *  - `serviceEnabled`: location switched on in the system.
 *  - `current` {timeoutMs, background, title, text, channel}: one fresh
 *    position. GPS and network are asked together; a precise answer ends
 *    the reading at once, otherwise the best answer when every provider has
 *    answered or the time is up. `background`: read for the background
 *    service; without the background permission the reading runs under a
 *    foreground service of the location type ([ZenLocationService], with
 *    the notification Dart gives), the only way such a reading is allowed.
 *  - `lastKnown`: the newest position any provider still keeps, or null.
 *
 * A position is {lat, lon, accuracy (metres), at (ms since the epoch)}.
 */
object ZenLocationBridge {
    private const val TAG = "ZenLocation"

    /** An answer this precise (metres) ends the reading. */
    private const val PRECISE_ENOUGH_M = 30f

    /** Longest wait for the location service to come up. */
    private const val SERVICE_START_WAIT_MS = 3_000L

    private var requestSerial = 0
    private const val CHANNEL = "zen/location"

    /** [engine] is going away: its handler (it may hold the Activity) goes with it. */
    fun unregister(engine: FlutterEngine) {
        engine.dartExecutor.binaryMessenger.setMessageHandler(CHANNEL, null)
    }

    fun register(engine: FlutterEngine, context: Context, activity: FragmentActivity?) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "check" -> result.success(status(app))
                        "request" -> request(app, activity) { result.success(it) }
                        "serviceEnabled" -> result.success(serviceEnabled(app))
                        "current" -> {
                            val timeoutMs =
                                (call.argument<Number>("timeoutMs")?.toLong() ?: 12_000L)
                                    .coerceIn(1_000L, 120_000L)
                            val done: (Location?) -> Unit = { location ->
                                if (location == null) {
                                    result.error("timeout", "No position in time", null)
                                } else {
                                    result.success(toMap(location))
                                }
                            }
                            if (call.argument<Boolean>("background") == true) {
                                currentInBackground(
                                    app,
                                    timeoutMs,
                                    call.argument<String>("title") ?: "Zen",
                                    call.argument<String>("text") ?: "",
                                    call.argument<String>("channel") ?: "Zen",
                                    done,
                                )
                            } else {
                                current(app, timeoutMs, done)
                            }
                        }
                        "lastKnown" -> result.success(lastKnown(app)?.let { toMap(it) })
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    Log.w(TAG, "${call.method} failed", error)
                    result.error("unavailable", error.message, null)
                }
            }
    }

    // --- Permissions ------------------------------------------------------

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    private fun fine(context: Context) = granted(context, Manifest.permission.ACCESS_FINE_LOCATION)

    private fun anyLocation(context: Context) =
        fine(context) || granted(context, Manifest.permission.ACCESS_COARSE_LOCATION)

    /** Before Android 10 the location permission covers the background too. */
    private fun background(context: Context) =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)

    private fun status(context: Context): String = when {
        !anyLocation(context) -> "denied"
        background(context) -> "always"
        else -> "whileInUse"
    }

    private fun request(context: Context, activity: FragmentActivity?, done: (String) -> Unit) {
        if (activity == null || anyLocation(context)) {
            done(status(context))
            return
        }
        // The Activity's own result registry: no Activity callback to forward.
        var launcher: ActivityResultLauncher<Array<String>>? = null
        val registered = activity.activityResultRegistry.register(
            "zen_location_${requestSerial++}",
            ActivityResultContracts.RequestMultiplePermissions(),
        ) { grants ->
            launcher?.unregister()
            done(
                when {
                    anyLocation(context) -> status(context)
                    grants.isEmpty() -> "denied"
                    // Refused and the system will not ask again.
                    !ActivityCompat.shouldShowRequestPermissionRationale(
                        activity,
                        Manifest.permission.ACCESS_FINE_LOCATION,
                    ) && !ActivityCompat.shouldShowRequestPermissionRationale(
                        activity,
                        Manifest.permission.ACCESS_COARSE_LOCATION,
                    ) -> "deniedForever"
                    else -> "denied"
                },
            )
        }
        launcher = registered
        registered.launch(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
        )
    }

    // --- Positions --------------------------------------------------------

    private fun manager(context: Context): LocationManager? =
        context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    private fun serviceEnabled(context: Context): Boolean {
        val manager = manager(context) ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return manager.isLocationEnabled
        }
        return enabled(manager, LocationManager.GPS_PROVIDER) ||
            enabled(manager, LocationManager.NETWORK_PROVIDER)
    }

    private fun enabled(manager: LocationManager, provider: String): Boolean = try {
        manager.isProviderEnabled(provider)
    } catch (_: Exception) {
        false
    }

    /** The providers this app may ask now: GPS needs the precise permission. */
    private fun providers(context: Context, manager: LocationManager): List<String> {
        if (!anyLocation(context)) {
            return emptyList()
        }
        return buildList {
            if (fine(context)) {
                add(LocationManager.GPS_PROVIDER)
            }
            add(LocationManager.NETWORK_PROVIDER)
        }.filter { enabled(manager, it) }
    }

    private fun current(context: Context, timeoutMs: Long, done: (Location?) -> Unit) {
        val manager = manager(context)
        val providers = manager?.let { providers(context, it) }.orEmpty()
        if (manager == null || providers.isEmpty()) {
            done(null)
            return
        }
        Reading(context, manager, providers, timeoutMs, done).start()
    }

    private fun currentInBackground(
        context: Context,
        timeoutMs: Long,
        title: String,
        text: String,
        channel: String,
        done: (Location?) -> Unit,
    ) {
        if (!anyLocation(context) || background(context)) {
            current(context, timeoutMs, done)
            return
        }
        val main = Handler(Looper.getMainLooper())
        val startedAt = SystemClock.elapsedRealtime()
        var reading = false
        val read = {
            if (!reading) {
                reading = true
                // The wait for the service counts against the time limit.
                val left = timeoutMs - (SystemClock.elapsedRealtime() - startedAt)
                current(context, left.coerceAtLeast(1_000L)) { location ->
                    ZenLocationService.release(context)
                    done(location)
                }
            }
        }
        main.postDelayed({ read() }, SERVICE_START_WAIT_MS)
        ZenLocationService.acquire(context, title, text, channel) { read() }
    }

    private fun lastKnown(context: Context): Location? {
        val manager = manager(context) ?: return null
        if (!anyLocation(context)) {
            return null
        }
        return listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER,
        ).mapNotNull {
            try {
                manager.getLastKnownLocation(it)
            } catch (_: Exception) {
                // Not allowed with the approximate permission, or missing.
                null
            }
        }.maxByOrNull { it.elapsedRealtimeNanos }
    }

    private fun toMap(location: Location): Map<String, Any> = mapOf(
        "lat" to location.latitude,
        "lon" to location.longitude,
        "accuracy" to (if (location.hasAccuracy()) location.accuracy.toDouble() else 0.0),
        "at" to location.time,
    )

    private fun accuracyOf(location: Location): Float =
        if (location.hasAccuracy()) location.accuracy else Float.MAX_VALUE

    /**
     * One reading over [providers], on the main thread: getCurrentLocation
     * on Android 11+, single updates before that; ends with the best
     * position (or null) exactly once.
     */
    private class Reading(
        private val context: Context,
        private val manager: LocationManager,
        private val providers: List<String>,
        private val timeoutMs: Long,
        private val done: (Location?) -> Unit,
    ) {
        private val main = Handler(Looper.getMainLooper())
        private val cancel = CancellationSignal()
        private val listeners = ArrayList<LocationListener>()
        private val answered = HashSet<String>()
        private var best: Location? = null
        private var finished = false
        private val timeout = Runnable { finish() }

        fun start() {
            main.postDelayed(timeout, timeoutMs)
            for (provider in providers) {
                if (finished) {
                    return
                }
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        manager.getCurrentLocation(
                            provider,
                            cancel,
                            ContextCompat.getMainExecutor(context),
                        ) { location -> onAnswer(provider, location) }
                    } else {
                        val listener = Listener(provider)
                        listeners.add(listener)
                        manager.requestLocationUpdates(
                            provider,
                            0L,
                            0f,
                            listener,
                            Looper.getMainLooper(),
                        )
                    }
                } catch (error: Exception) {
                    Log.w(TAG, "Reading $provider failed", error)
                    onAnswer(provider, null)
                }
            }
        }

        private fun onAnswer(provider: String, location: Location?) {
            if (finished) {
                return
            }
            answered.add(provider)
            val previous = best
            if (location != null && (previous == null || accuracyOf(location) < accuracyOf(previous))) {
                best = location
            }
            val now = best
            if ((now != null && accuracyOf(now) <= PRECISE_ENOUGH_M) ||
                answered.containsAll(providers)
            ) {
                finish()
            }
        }

        private fun finish() {
            if (finished) {
                return
            }
            finished = true
            main.removeCallbacks(timeout)
            cancel.cancel()
            for (listener in listeners) {
                try {
                    manager.removeUpdates(listener)
                } catch (_: Exception) {
                }
            }
            listeners.clear()
            done(best)
        }

        /**
         * Before Android 11 every method of LocationListener is abstract:
         * all of them are implemented here.
         */
        private inner class Listener(private val provider: String) : LocationListener {
            override fun onLocationChanged(location: Location) = onAnswer(provider, location)

            override fun onProviderDisabled(provider: String) = onAnswer(this.provider, null)

            override fun onProviderEnabled(provider: String) {}

            @Deprecated("Never called on Android 10+")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        }
    }
}

/**
 * A foreground service of the location type, up only while the background
 * service reads the alarm's position without the background permission
 * (Android 10+ gives a closed app the position only under such a service).
 * It does nothing but show its notification; [ZenLocationBridge] starts and
 * stops it. Everything here runs on the main thread.
 */
class ZenLocationService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // Created again with the current language's name.
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        intent?.getStringExtra(EXTRA_CHANNEL) ?: "Zen",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply { setShowBadge(false) },
                )
            }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
            val notification = builder
                .setSmallIcon(R.drawable.tiny_notification)
                .setContentTitle(intent?.getStringExtra(EXTRA_TITLE) ?: "Zen")
                .setContentText(intent?.getStringExtra(EXTRA_TEXT) ?: "")
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            state = State.RUNNING
            flush(true)
            if (users == 0) {
                stopNow(this)
            }
        } catch (error: Exception) {
            // Not allowed now (Android 12+ from the background, or the
            // permission went away): the reading goes on without it.
            Log.w(TAG, "Location service could not start", error)
            state = State.IDLE
            flush(false)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (state == State.RUNNING) {
            state = State.IDLE
        }
        super.onDestroy()
    }

    companion object {
        private const val TAG = "ZenLocationService"
        private const val CHANNEL_ID = "zen_alarm_location"
        private const val NOTIFICATION_ID = 7341
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_CHANNEL = "channel"

        private enum class State { IDLE, STARTING, RUNNING }

        private var state = State.IDLE
        private var users = 0
        private val waiting = ArrayList<(Boolean) -> Unit>()

        private fun flush(running: Boolean) {
            val ready = ArrayList(waiting)
            waiting.clear()
            ready.forEach { it(running) }
        }

        private fun stopNow(context: Context) {
            state = State.IDLE
            context.stopService(Intent(context, ZenLocationService::class.java))
        }

        /** One more reading needs the service; [ready] once it is up (or not). */
        fun acquire(
            context: Context,
            title: String,
            text: String,
            channel: String,
            ready: (Boolean) -> Unit,
        ) {
            users++
            when (state) {
                State.RUNNING -> ready(true)
                State.STARTING -> waiting.add(ready)
                State.IDLE -> {
                    state = State.STARTING
                    waiting.add(ready)
                    try {
                        ContextCompat.startForegroundService(
                            context,
                            Intent(context, ZenLocationService::class.java)
                                .putExtra(EXTRA_TITLE, title)
                                .putExtra(EXTRA_TEXT, text)
                                .putExtra(EXTRA_CHANNEL, channel),
                        )
                    } catch (error: Exception) {
                        Log.w(TAG, "Location service not allowed now", error)
                        state = State.IDLE
                        flush(false)
                    }
                }
            }
        }

        /** A reading is over; the last one stops the service. */
        fun release(context: Context) {
            if (users == 0) {
                return
            }
            users--
            // Still starting: onStartCommand stops it once it is up.
            if (users == 0 && state == State.RUNNING) {
                stopNow(context)
            }
        }
    }
}
