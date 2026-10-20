package com.roj.zen

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Rational
import android.view.WindowManager
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FragmentActivity: the system biometric prompt (key vault, §14.1) and
// local_auth need it.
class MainActivity : FlutterFragmentActivity() {

    /** A call is running: leaving the app shrinks it into picture-in-picture. */
    private var pipCallActive = false
    private var pipVideo = false
    private var pipHangUpReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        clearShowWhenLockedFlags()
        registerPipHangUpReceiver()
    }

    override fun onResume() {
        super.onResume()
        clearShowWhenLockedFlags()
        isResumed = true
    }

    override fun onPause() {
        isResumed = false
        super.onPause()
    }

    override fun onDestroy() {
        pipHangUpReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        pipHangUpReceiver = null
        super.onDestroy()
    }

    private fun clearShowWhenLockedFlags() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(false)
            setTurnScreenOn(false)
        }
        @Suppress("DEPRECATION")
        window.clearFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ZenCallBridge.register(flutterEngine, this)
        ZenSecurityBridge.register(flutterEngine, this)
        ZenUpdateBridge.register(flutterEngine, this)
        ZenSystemBridge.register(flutterEngine, this)
        ZenMulticastLock.register(flutterEngine, this)
        ZenNearbyBridge.register(flutterEngine, this)
        ZenWifiDirectBridge.register(flutterEngine, this)
        ZenBluetoothLinkBridge.register(flutterEngine, this)
        ZenPermissionsBridge.register(flutterEngine, this)
        ZenAlarmShortcut.register(flutterEngine, this, background = false)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        ZenCallBridge.unregister(flutterEngine)
        // Only this engine's share of the radio stops; the background
        // service keeps whatever it still uses (§15, §16.3).
        ZenNearbyBridge.unregister(flutterEngine)
        ZenWifiDirectBridge.unregister(flutterEngine)
        ZenBluetoothLinkBridge.unregister(flutterEngine)
        ZenAlarmShortcut.unregister(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // --- Picture-in-picture for calls ------------------------------------

    private fun supportsPip(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /** Called from Dart whenever a call starts or ends. */
    fun setPipCall(active: Boolean, video: Boolean) {
        pipCallActive = active
        pipVideo = video
        if (!supportsPip()) {
            return
        }
        try {
            // Android 12+: the system shrinks the app by itself on "home".
            setPictureInPictureParams(pipParams())
        } catch (error: Exception) {
            Log.w(TAG, "Updating picture-in-picture params failed", error)
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(if (pipVideo) Rational(3, 4) else Rational(16, 9))
        if (pipCallActive) {
            val hangUp = PendingIntent.getBroadcast(
                this,
                PIP_HANG_UP_REQUEST,
                Intent(ACTION_PIP_HANG_UP).setPackage(packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.setActions(
                listOf(
                    RemoteAction(
                        Icon.createWithResource(this, R.drawable.ic_pip_hang_up),
                        getString(R.string.call_hang_up),
                        getString(R.string.call_hang_up),
                        hangUp,
                    ),
                ),
            )
        } else {
            builder.setActions(emptyList())
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipCallActive)
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Before Android 12 there is no auto-enter: go small by hand.
        if (pipCallActive && supportsPip() && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            try {
                enterPictureInPictureMode(pipParams())
            } catch (error: Exception) {
                // Turned off by the user for this app, or not allowed now.
                Log.w(TAG, "Entering picture-in-picture failed", error)
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        ZenCallBridge.dispatchPipChanged(isInPictureInPictureMode)
    }

    private fun registerPipHangUpReceiver() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == ACTION_PIP_HANG_UP) {
                    ZenCallBridge.dispatchPipAction("hangup")
                }
            }
        }
        try {
            ContextCompat.registerReceiver(
                this,
                receiver,
                IntentFilter(ACTION_PIP_HANG_UP),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            pipHangUpReceiver = receiver
        } catch (error: Exception) {
            Log.w(TAG, "Registering the picture-in-picture receiver failed", error)
        }
    }

    companion object {
        private const val TAG = "ZenMain"
        private const val ACTION_PIP_HANG_UP = "com.roj.zen.PIP_HANG_UP"
        private const val PIP_HANG_UP_REQUEST = 9201

        @Volatile
        var isResumed: Boolean = false
            private set

        init {
            // Load the Go bridge through the JVM so JNI_OnLoad runs. Dart FFI
            // dlopen skips that, which leaves Android DNS/sockets uninitialized
            // inside the c-shared runtime.
            try {
                System.loadLibrary("yggdrasil_bridge")
            } catch (_: UnsatisfiedLinkError) {
            }
        }
    }
}
