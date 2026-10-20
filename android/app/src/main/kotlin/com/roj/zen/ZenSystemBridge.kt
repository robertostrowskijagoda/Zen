package com.roj.zen

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Small system actions (`zen/system`): open the dialer with a number (the
 * person presses call; no permission needed), open the SMS app with a
 * ready text (no SEND_SMS permission), open a map at a place, tell
 * the Android API level (which foreground-service type the background
 * service may use), open this app's page in the system settings (where
 * phone makers keep their own battery limits), open the "open by default"
 * page (so a Zen QR scanned with the camera opens straight in Zen) and open
 * an https page in the browser. `setDisguise` switches the launcher entry
 * between Zen's own icon and name and a neutral notes one (two
 * activity-aliases, exactly one enabled; §14.2). `soundsSilenced` tells
 * whether the phone keeps quiet (Zen's in-app sounds follow it).
 */
object ZenSystemBridge {
    private const val TAG = "ZenSystem"

    fun register(engine: FlutterEngine, activity: FragmentActivity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "zen/system")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "dial" -> {
                            val number = call.argument<String>("number") ?: ""
                            activity.startActivity(
                                Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(number))),
                            )
                            result.success(true)
                        }
                        "sms" -> {
                            // The system SMS app with the text ready; the
                            // person presses send (no SEND_SMS permission).
                            val numbers = call.argument<List<String>>("numbers") ?: emptyList()
                            val body = call.argument<String>("body") ?: ""
                            val to = numbers.joinToString(";") { Uri.encode(it, "+") }
                            activity.startActivity(
                                Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$to"))
                                    .putExtra("sms_body", body),
                            )
                            result.success(true)
                        }
                        "openMap" -> {
                            val lat = call.argument<Double>("lat") ?: 0.0
                            val lon = call.argument<Double>("lon") ?: 0.0
                            val label = Uri.encode(call.argument<String>("label") ?: "")
                            val geo = Intent(
                                Intent.ACTION_VIEW,
                                Uri.parse("geo:$lat,$lon?q=$lat,$lon($label)"),
                            )
                            if (geo.resolveActivity(activity.packageManager) != null) {
                                activity.startActivity(geo)
                            } else {
                                activity.startActivity(
                                    Intent(
                                        Intent.ACTION_VIEW,
                                        Uri.parse("https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=17/$lat/$lon"),
                                    ),
                                )
                            }
                            result.success(true)
                        }
                        "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                        "soundsSilenced" -> result.success(soundsSilenced(activity))
                        "openUrl" -> result.success(openInBrowser(activity, call.argument<String>("url")))
                        "openLinkSettings" -> {
                            val page = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS
                            } else {
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                            }
                            activity.startActivity(
                                Intent(page, Uri.parse("package:${activity.packageName}")),
                            )
                            result.success(true)
                        }
                        "openAppSettings" -> {
                            activity.startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:${activity.packageName}"),
                                ),
                            )
                            result.success(true)
                        }
                        "setDisguise" -> result.success(
                            setDisguise(activity, call.argument<Boolean>("enabled") ?: false),
                        )
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    Log.w(TAG, "${call.method} failed", error)
                    result.success(false)
                }
            }
    }

    private fun alias(activity: FragmentActivity, name: String) =
        ComponentName(activity.packageName, "${activity.packageName}.$name")

    /**
     * Enables the launcher alias for the wanted look and disables the other,
     * so exactly one launcher entry exists. The wanted one is enabled first:
     * there is never a moment with none. DONT_KILL_APP keeps the app running
     * (some launchers still take a moment to refresh their icon).
     */
    private fun setDisguise(activity: FragmentActivity, enabled: Boolean): Boolean {
        val pm = activity.packageManager
        val on = alias(activity, if (enabled) "LauncherDisguise" else "LauncherDefault")
        val off = alias(activity, if (enabled) "LauncherDefault" else "LauncherDisguise")
        pm.setComponentEnabledSetting(
            on,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        pm.setComponentEnabledSetting(
            off,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
        return true
    }

    /**
     * Only https, and in a browser: Zen itself answers links to its own
     * GitHub page (invitations), so a plain VIEW could come straight back.
     */
    /**
     * Whether the phone is set to keep quiet: silent or vibrate mode, or
     * "Do not disturb" in any form. Zen's in-app sounds stay silent then.
     */
    private fun soundsSilenced(context: Context): Boolean {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        if (audio != null && audio.ringerMode != AudioManager.RINGER_MODE_NORMAL) {
            return true
        }
        val notifications =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            notifications != null &&
            notifications.currentInterruptionFilter > NotificationManager.INTERRUPTION_FILTER_ALL
    }

    private fun openInBrowser(activity: FragmentActivity, url: String?): Boolean {
        val uri = Uri.parse(url ?: return false)
        if (uri.scheme != "https" || uri.host.isNullOrEmpty()) {
            return false
        }
        val view = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
        return try {
            activity.startActivity(
                Intent(view).apply {
                    selector = Intent.makeMainSelectorActivity(
                        Intent.ACTION_MAIN,
                        Intent.CATEGORY_APP_BROWSER,
                    )
                },
            )
            true
        } catch (_: android.content.ActivityNotFoundException) {
            activity.startActivity(view)
            true
        }
    }
}
