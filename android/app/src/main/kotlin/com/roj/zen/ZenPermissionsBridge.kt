package com.roj.zen

import android.Manifest
import android.app.AlarmManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The permissions screen (§25.2, `zen/permissions`): what is allowed now,
 * and asking for one thing at a time (notifications, microphone, camera).
 * Bluetooth goes through [ZenNearbyBridge]; battery optimisation through
 * the foreground-service plugin. The system dialog answers later: the app
 * reads the state again when it is back on screen.
 */
object ZenPermissionsBridge {
    private const val TAG = "ZenPermissions"
    private const val PERMISSION_REQUEST = 3301

    fun register(engine: FlutterEngine, activity: FragmentActivity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "zen/permissions")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "state" -> result.success(state(activity))
                        "request" -> {
                            if (call.arguments as? String == "exactAlarms") {
                                result.success(openExactAlarmSettings(activity))
                                return@setMethodCallHandler
                            }
                            val missing = permissionsFor(call.arguments as? String).filter {
                                ContextCompat.checkSelfPermission(activity, it) !=
                                    PackageManager.PERMISSION_GRANTED
                            }
                            if (missing.isNotEmpty()) {
                                ActivityCompat.requestPermissions(
                                    activity,
                                    missing.toTypedArray(),
                                    PERMISSION_REQUEST,
                                )
                            }
                            result.success(missing.isEmpty())
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    Log.w(TAG, "${call.method} failed", error)
                    result.success(false)
                }
            }
    }

    /** The runtime permissions behind [name] on this Android version. */
    private fun permissionsFor(name: String?): List<String> = when (name) {
        "notifications" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                listOf(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                emptyList()
            }
        "microphone" -> listOf(Manifest.permission.RECORD_AUDIO)
        "camera" -> listOf(Manifest.permission.CAMERA)
        else -> emptyList()
    }

    private fun granted(context: Context, name: String): Boolean =
        permissionsFor(name).all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }

    /** Android 12+: exact alarms are a special access, given on a system page. */
    private fun canScheduleExactAlarms(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return true
        }
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        return alarms?.canScheduleExactAlarms() ?: true
    }

    private fun openExactAlarmSettings(activity: FragmentActivity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            canScheduleExactAlarms(activity)
        ) {
            return true
        }
        activity.startActivity(
            Intent(
                Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                Uri.parse("package:${activity.packageName}"),
            ),
        )
        return false
    }

    private fun state(context: Context): Map<String, Any> = mapOf(
        "exactAlarms" to canScheduleExactAlarms(context),
        "manufacturer" to Build.MANUFACTURER,
        // Before Android 13 there is nothing to ask, but the person may
        // have switched notifications off in the settings.
        "notifications" to (
            granted(context, "notifications") &&
                NotificationManagerCompat.from(context).areNotificationsEnabled()
            ),
        "microphone" to granted(context, "microphone"),
        "camera" to granted(context, "camera"),
        "sdk" to Build.VERSION.SDK_INT,
    )
}
