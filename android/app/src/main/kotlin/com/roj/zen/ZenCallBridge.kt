package com.roj.zen

import android.Manifest
import android.app.Activity
import android.app.ActivityOptions
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList

object ZenCallBridge {
    const val CHANNEL_NAME = "zen/calls"
    const val EXTRA_UNLOCK_FOR_CALL = "zen_unlock_for_call"
    const val EXTRA_SHOW_OVER_LOCK = "zen_show_over_lock"
    private const val TAG = "ZenIncomingCall"
    private const val INCOMING_CALL_CHANNEL_ID = "zen_incoming_call_ui_v3"
    private const val INCOMING_CALL_NOTIFICATION_ID = 9102

    @Volatile
    var pendingDisplayName: String = ""
        private set

    @Volatile
    var pendingIsVideo: Boolean = false
        private set

    @Volatile
    var pendingPeerAddress: String = ""
        private set

    @Volatile
    var pendingAcceptRouteKey: String = ""
        private set

    private val channels = CopyOnWriteArrayList<MethodChannel>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var appContext: Context? = null

    fun register(flutterEngine: FlutterEngine, context: Context) {
        appContext = context.applicationContext
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channels.add(channel)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "bringToFront" -> {
                    bringAppToFront(context)
                    result.success(true)
                }
                "canUseFullScreenIntent" -> {
                    result.success(canUseFullScreenIntent(context))
                }
                "setRingingCallActive" -> {
                    val active = call.arguments as? Boolean ?: false
                    setRingingCallActive(context, active)
                    result.success(null)
                }
                "showIncomingCallPopup" -> {
                    val args = call.arguments as? Map<*, *>
                    val displayName = args?.get("displayName") as? String ?: ""
                    val isVideo = args?.get("isVideo") as? Boolean ?: false
                    val peerAddress = args?.get("peerAddress") as? String ?: ""
                    val acceptRouteKey = args?.get("acceptRouteKey") as? String ?: ""
                    // No caller name in the system log: other apps with log access
                    // (or a bug report) would see who calls.
                    Log.i(TAG, "showIncomingCallPopup video=$isVideo")
                    showIncomingCallPopup(
                        context = context,
                        displayName = displayName,
                        isVideo = isVideo,
                        peerAddress = peerAddress,
                        acceptRouteKey = acceptRouteKey,
                    )
                    result.success(true)
                }
                "hideIncomingCallPopup" -> {
                    hideIncomingCallPopup()
                    result.success(null)
                }
                "unlockForCall" -> {
                    unlockForCall(context)
                    result.success(null)
                }
                "canDrawOverlays" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        result.success(Settings.canDrawOverlays(context))
                    } else {
                        result.success(true)
                    }
                }
                "openOverlaySettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:${context.packageName}")
                        ).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        context.startActivity(intent)
                    }
                    result.success(true)
                }
                "requestAllAppPermissions" -> {
                    if (context is Activity && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val permissionsToRequest = mutableListOf<String>()
                        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            permissionsToRequest.add(Manifest.permission.RECORD_AUDIO)
                        }
                        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                            permissionsToRequest.add(Manifest.permission.CAMERA)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                permissionsToRequest.add(Manifest.permission.POST_NOTIFICATIONS)
                            }
                        }
                        if (permissionsToRequest.isNotEmpty()) {
                            context.requestPermissions(permissionsToRequest.toTypedArray(), 2001)
                        }
                    }
                    result.success(true)
                }
                "checkPermissions" -> {
                    val audioGranted = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                    val cameraGranted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
                    val notifGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                    } else {
                        true
                    }
                    val overlayGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Settings.canDrawOverlays(context)
                    } else {
                        true
                    }
                    val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                    val batteryExempt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        powerManager?.isIgnoringBatteryOptimizations(context.packageName) ?: false
                    } else {
                        true
                    }
                    result.success(mapOf(
                        "audio" to audioGranted,
                        "camera" to cameraGranted,
                        "notifications" to notifGranted,
                        "overlay" to overlayGranted,
                        "batteryExempt" to batteryExempt
                    ))
                }
                "setPipCall" -> {
                    val args = call.arguments as? Map<*, *>
                    val active = args?.get("active") as? Boolean ?: false
                    val video = args?.get("video") as? Boolean ?: false
                    (context as? MainActivity)?.setPipCall(active, video)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun unregister(flutterEngine: FlutterEngine) {
        // Stale engines are skipped at dispatch time; dropping every channel
        // here would also kill the still-live foreground-service isolate.
    }

    fun dispatchIncomingCallAction(action: String, peerAddress: String) {
        val args = hashMapOf(
            "action" to action,
            "peerAddress" to peerAddress,
        )
        mainHandler.post {
            for (channel in channels) {
                try {
                    channel.invokeMethod("onIncomingCallAction", args)
                } catch (_: Exception) {
                }
            }
        }
    }

    /** Picture-in-picture entered or left (the call UI goes small or back). */
    fun dispatchPipChanged(inPip: Boolean) {
        mainHandler.post {
            for (channel in channels) {
                try {
                    channel.invokeMethod("onPipChanged", inPip)
                } catch (_: Exception) {
                }
            }
        }
    }

    /** A button of the picture-in-picture window ("hangup"). */
    fun dispatchPipAction(action: String) {
        mainHandler.post {
            for (channel in channels) {
                try {
                    channel.invokeMethod("onPipAction", action)
                } catch (_: Exception) {
                }
            }
        }
    }

    fun showIncomingCallPopup(
        context: Context,
        displayName: String,
        isVideo: Boolean,
        peerAddress: String,
        acceptRouteKey: String,
    ) {
        pendingDisplayName = displayName
        pendingIsVideo = isVideo
        pendingPeerAddress = peerAddress
        pendingAcceptRouteKey = acceptRouteKey
        val appContext = context.applicationContext
        mainHandler.post {
            presentIncomingCall(
                appContext = appContext,
                displayName = displayName,
                isVideo = isVideo,
                peerAddress = peerAddress,
                acceptRouteKey = acceptRouteKey,
            )
        }
    }

    private fun presentIncomingCall(
        appContext: Context,
        displayName: String,
        isVideo: Boolean,
        peerAddress: String,
        acceptRouteKey: String,
    ) {
        if (IncomingCallActivity.isShowing || IncomingCallUi.isOverlayShowing) {
            Log.i(TAG, "Incoming UI already visible")
            return
        }
        wakeUpScreen(appContext)
        val lockedOrOff = isKeyguardLocked(appContext) || !isScreenInteractive(appContext)
        if (!lockedOrOff) {
            val overlayOk = IncomingCallUi.showOverlay(
                appContext,
                displayName = displayName,
                isVideo = isVideo,
                onAccept = {
                    IncomingCallUi.hideOverlay(appContext)
                    dispatchIncomingCallAction("accept", peerAddress)
                    launchMainForAccept(appContext, acceptRouteKey, peerAddress)
                },
                onDecline = {
                    IncomingCallUi.hideOverlay(appContext)
                    dispatchIncomingCallAction("decline", peerAddress)
                    cancelIncomingCallLaunchNotification(appContext)
                },
            )
            if (overlayOk) {
                Log.i(TAG, "Showing overlay popup")
                return
            }
        }
        val launch = incomingCallLaunchIntent(
            appContext,
            displayName = displayName,
            isVideo = isVideo,
            peerAddress = peerAddress,
            acceptRouteKey = acceptRouteKey,
        )
        launchIncomingCallActivity(appContext, launch)
        Log.i(TAG, "Launched lock-screen popup lockedOrOff=$lockedOrOff")
    }

    private fun incomingCallLaunchIntent(
        context: Context,
        displayName: String,
        isVideo: Boolean,
        peerAddress: String,
        acceptRouteKey: String,
    ): Intent {
        return Intent(IncomingCallActivity.ACTION_INCOMING_CALL).apply {
            setClass(context, IncomingCallActivity::class.java)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION,
            )
            putExtra(IncomingCallActivity.EXTRA_DISPLAY_NAME, displayName)
            putExtra(IncomingCallActivity.EXTRA_IS_VIDEO, isVideo)
            putExtra(IncomingCallActivity.EXTRA_PEER_ADDRESS, peerAddress)
            putExtra(IncomingCallActivity.EXTRA_ACCEPT_ROUTE, acceptRouteKey)
        }
    }

    private fun launchIncomingCallActivity(appContext: Context, launch: Intent) {
        val pi = PendingIntent.getActivity(
            appContext,
            INCOMING_CALL_NOTIFICATION_ID,
            launch,
            pendingIntentFlags(),
        )
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val options = ActivityOptions.makeBasic().apply {
                    pendingIntentBackgroundActivityStartMode =
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                }
                pi.send(appContext, 0, null, null, null, null, options.toBundle())
            } else {
                pi.send()
            }
        } catch (error: Exception) {
            Log.w(TAG, "PendingIntent launch failed", error)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val options = ActivityOptions.makeBasic().apply {
                    pendingIntentBackgroundActivityStartMode =
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                }
                appContext.startActivity(launch, options.toBundle())
            } else {
                appContext.startActivity(launch)
            }
        } catch (error: Exception) {
            Log.w(TAG, "startActivity launch failed", error)
        }
    }

    fun launchMainForAccept(context: Context, routeKey: String, peerAddress: String) {
        // Only the app's own call routes reach MainActivity; anything else in
        // the extra (stale or forged) falls back to the plain call route.
        val route = routeKey.takeIf { it.isNotBlank() }?.let { Uri.parse(it) }
        val uri = if (route != null && route.scheme.equals("zen", ignoreCase = true)) {
            route
        } else {
            // Opens the call screen; answering still needs the user (a bare
            // `accept=1` is ignored by the app, only its own token counts).
            Uri.parse("zen://call/${Uri.encode(peerAddress)}")
        }
        val launch = Intent(Intent.ACTION_VIEW, uri).apply {
            setClass(context, MainActivity::class.java)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
        }
        try {
            context.startActivity(launch)
        } catch (_: Exception) {
            bringAppToFront(context)
        }
    }

    private fun pendingIntentFlags(): Int {
        return PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            })
    }

    private fun actionBroadcastIntent(
        context: Context,
        action: String,
        peerAddress: String,
        acceptRouteKey: String,
        requestCode: Int,
    ): PendingIntent {
        val intent = Intent(context, IncomingCallActionReceiver::class.java).apply {
            this.action = action
            putExtra(IncomingCallActivity.EXTRA_PEER_ADDRESS, peerAddress)
            putExtra(IncomingCallActivity.EXTRA_ACCEPT_ROUTE, acceptRouteKey)
        }
        return PendingIntent.getBroadcast(context, requestCode, intent, pendingIntentFlags())
    }

    private fun postIncomingCallLaunchNotification(
        context: Context,
        displayName: String,
        isVideo: Boolean,
        peerAddress: String,
        acceptRouteKey: String,
        fullScreenLaunch: Intent,
    ) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        ensureIncomingCallLaunchChannel(context, manager)
        val accept = actionBroadcastIntent(
            context,
            IncomingCallActionReceiver.ACTION_ACCEPT,
            peerAddress,
            acceptRouteKey,
            9111,
        )
        val decline = actionBroadcastIntent(
            context,
            IncomingCallActionReceiver.ACTION_DECLINE,
            peerAddress,
            acceptRouteKey,
            9112,
        )
        val fullScreen = PendingIntent.getActivity(
            context,
            INCOMING_CALL_NOTIFICATION_ID,
            fullScreenLaunch,
            pendingIntentFlags(),
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, INCOMING_CALL_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_call)
            .setContentTitle(displayName)
            .setContentText(
                context.getString(
                    if (isVideo) R.string.call_notification_video else R.string.call_notification_audio,
                ),
            )
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(fullScreen)
            .setFullScreenIntent(fullScreen, true)
            .addAction(0, context.getString(R.string.call_decline), decline)
            .addAction(0, context.getString(R.string.call_accept), accept)
        try {
            manager.notify(INCOMING_CALL_NOTIFICATION_ID, builder.build())
        } catch (error: Exception) {
            Log.e(TAG, "Incoming-call notification failed", error)
        }
    }

    private fun ensureIncomingCallLaunchChannel(context: Context, manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val existing = manager.getNotificationChannel(INCOMING_CALL_CHANNEL_ID)
        if (existing != null) {
            return
        }
        val channel = NotificationChannel(
            INCOMING_CALL_CHANNEL_ID,
            context.getString(R.string.call_channel_name),
            NotificationManager.IMPORTANCE_MAX,
        )
        val ringtone = android.provider.Settings.System.DEFAULT_RINGTONE_URI
        val attrs = android.media.AudioAttributes.Builder()
            .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        channel.setSound(ringtone, attrs)
        channel.enableVibration(true)
        channel.vibrationPattern = longArrayOf(0, 500, 200, 500, 200, 800)
        channel.setBypassDnd(true)
        channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    fun cancelIncomingCallLaunchNotification(context: Context) {
        try {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.cancel(INCOMING_CALL_NOTIFICATION_ID)
        } catch (_: Exception) {
        }
    }

    private fun isKeyguardLocked(context: Context): Boolean {
        val km = context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        return km?.isKeyguardLocked == true
    }

    private fun isScreenInteractive(context: Context): Boolean {
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return pm?.isInteractive == true
    }

    fun hideIncomingCallPopup() {
        pendingDisplayName = ""
        pendingIsVideo = false
        pendingPeerAddress = ""
        pendingAcceptRouteKey = ""
        val context = appContext
        mainHandler.post {
            IncomingCallActivity.finishIfShowing()
            if (context != null) {
                IncomingCallUi.hideOverlay(context)
                cancelIncomingCallLaunchNotification(context)
            }
        }
    }

    fun wakeUpScreen(context: Context) {
        try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            val flags = PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE
            val wakeLock = powerManager?.newWakeLock(flags, "zen:call_wakeup")
            wakeLock?.acquire(4000)
            wakeLock?.release()
        } catch (_: Exception) {
        }
    }

    fun bringAppToFront(context: Context) {
        wakeUpScreen(context)
        val pm = context.packageManager
        val launchIntent = (pm.getLaunchIntentForPackage(context.packageName) ?: Intent(context, MainActivity::class.java)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("route", "/call")
            putExtra("incoming_call", true)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val options = ActivityOptions.makeBasic().apply {
                    pendingIntentBackgroundActivityStartMode =
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                }
                context.startActivity(launchIntent, options.toBundle())
            } else {
                context.startActivity(launchIntent)
            }
        } catch (_: Exception) {
            try {
                val pi = PendingIntent.getActivity(
                    context,
                    8888,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
                )
                pi.send()
            } catch (_: Exception) {
            }
        }
    }

    fun canUseFullScreenIntent(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return true
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        return manager?.canUseFullScreenIntent() ?: false
    }

    fun setRingingCallActive(context: Context, active: Boolean) {
        if (active) {
            wakeUpScreen(context)
        }
        if (context is Activity) {
            if (active) {
                context.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                context.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            // MainActivity contains sensitive user conversations and must never be displayed
            // over the keyguard without unlocking. Only IncomingCallActivity is shown
            // over the lock screen.
            if (context is MainActivity) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    context.setShowWhenLocked(false)
                    context.setTurnScreenOn(false)
                }
                @Suppress("DEPRECATION")
                context.window.clearFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            } else {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    context.setShowWhenLocked(active)
                    context.setTurnScreenOn(active)
                } else {
                    @Suppress("DEPRECATION")
                    val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                    if (active) {
                        context.window.addFlags(flags)
                    } else {
                        context.window.clearFlags(flags)
                    }
                }
            }
        }
    }

    fun showOverLockWithoutUnlock(activity: Activity) {
        wakeUpScreen(activity)
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            activity.setShowWhenLocked(true)
            activity.setTurnScreenOn(true)
        }
        @Suppress("DEPRECATION")
        activity.window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
        )
    }

    fun unlockForCall(context: Context) {
        val activity = context as? Activity ?: return
        wakeUpScreen(activity)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            val km = activity.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            km?.requestDismissKeyguard(activity, null)
        } else {
            @Suppress("DEPRECATION")
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD)
        }
    }
}
