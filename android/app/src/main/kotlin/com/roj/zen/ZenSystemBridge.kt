package com.roj.zen

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Small system actions (`zen/system`): open the dialer with a number (the
 * person presses call; no permission needed), open a map at a place, tell
 * the Android API level (which foreground-service type the background
 * service may use), open this app's page in the system settings (where
 * phone makers keep their own battery limits), open the "open by default"
 * page (so a Zen QR scanned with the camera opens straight in Zen) and open
 * an https page in the browser.
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
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    Log.w(TAG, "${call.method} failed", error)
                    result.success(false)
                }
            }
    }

    /**
     * Only https, and in a browser: Zen itself answers links to its own
     * GitHub page (invitations), so a plain VIEW could come straight back.
     */
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
