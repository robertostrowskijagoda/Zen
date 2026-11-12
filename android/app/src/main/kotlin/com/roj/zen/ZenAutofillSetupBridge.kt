package com.roj.zen

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** Chrome's answer about its "Autofill using another service" switch. */
const val BROWSER_SWITCH_UNKNOWN = -1
const val BROWSER_SWITCH_OFF = 0
const val BROWSER_SWITCH_ON = 1

/** At most this many browsers are looked at in one call. */
const val MAX_SETUP_BROWSERS = 40

private val setupPackagePattern = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")

/**
 * The packages of [raw] that are package names, each once, at most
 * [MAX_SETUP_BROWSERS]: anything else Dart sent is left out.
 */
fun setupBrowserPackages(raw: Any?): List<String> =
    (raw as? List<*>).orEmpty()
        .filterIsInstance<String>()
        .filter { it.length <= 255 && setupPackagePattern.matches(it) }
        .distinct()
        .take(MAX_SETUP_BROWSERS)

/**
 * Where a Chromium browser tells whether it hands web forms to the phone's
 * autofill service (Chrome 135+, the Android Developers Blog, February 2025).
 */
fun thirdPartyModeUri(browser: String): String =
    "content://$browser.AutofillThirdPartyModeContentProvider/autofill_third_party_mode"

const val THIRD_PARTY_MODE_COLUMN = "autofill_third_party_state"

/** The provider's value as on, off or unknown (any value it did not document). */
fun thirdPartyModeState(value: Int?): Int = when (value) {
    0 -> BROWSER_SWITCH_OFF
    1 -> BROWSER_SWITCH_ON
    else -> BROWSER_SWITCH_UNKNOWN
}

/**
 * The browsers' side of the password manager's setup (`zen/autofill_setup`,
 * password_setup.dart). Dart names the browsers; this only says which are
 * installed and what they answer:
 * * `browsers` {packages, switches} → [{package, label, state, settings}]
 *   for every installed one of [packages]; for those also in [switches],
 *   `state` is their "Autofill using another service" switch (1 on, 0 off,
 *   -1 unknown) and `settings` whether their page with it can be opened;
 * * `openBrowserSettings` {package}: that page, only when it resolves in
 *   that very package (never a chooser).
 *
 * Reading another app's provider may start that app: done off the main
 * thread. Nothing here goes to the log beyond that a call failed.
 */
object ZenAutofillSetupBridge {
    private const val TAG = "ZenAutofillSetup"
    private const val CHANNEL = "zen/autofill_setup"

    private val main = Handler(Looper.getMainLooper())
    private val work = Executors.newSingleThreadExecutor { Thread(it, "zen-autofill-setup") }
    private var channel: MethodChannel? = null
    private var channelEngine: FlutterEngine? = null

    /** [engine] is going away: its handler (it holds the Activity) goes with it. */
    fun unregister(engine: FlutterEngine) {
        if (channelEngine !== engine) {
            return
        }
        channel?.setMethodCallHandler(null)
        channel = null
        channelEngine = null
    }

    fun register(engine: FlutterEngine, activity: Activity) {
        val c = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = c
        channelEngine = engine
        c.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // Zen fills nothing before Android 9: nothing to set up.
                    "browsers" -> if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
                        result.success(emptyList<Map<String, Any?>>())
                    } else {
                        val packages = setupBrowserPackages(call.argument<Any>("packages"))
                        val switches = setupBrowserPackages(call.argument<Any>("switches")).toSet()
                        val app = activity.applicationContext
                        try {
                            work.execute {
                                val found = try {
                                    packages.mapNotNull { describe(app.packageManager, app, it, it in switches) }
                                } catch (error: Exception) {
                                    Log.w(TAG, "Looking at the browsers failed: ${error.javaClass.simpleName}")
                                    emptyList()
                                }
                                main.post { result.success(found) }
                            }
                        } catch (_: RejectedExecutionException) {
                            result.success(emptyList<Map<String, Any?>>())
                        }
                    }
                    "openBrowserSettings" -> {
                        val browser = setupBrowserPackages(listOf(call.argument<String>("package"))).firstOrNull()
                        result.success(
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                                browser != null &&
                                open(activity, browser),
                        )
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                Log.w(TAG, "Autofill setup call failed: ${error.javaClass.simpleName}")
                result.success(null)
            }
        }
    }

    private fun describe(
        pm: PackageManager,
        context: Context,
        browser: String,
        hasSwitch: Boolean,
    ): Map<String, Any?>? {
        val info = try {
            @Suppress("DEPRECATION")
            pm.getApplicationInfo(browser, 0)
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        }
        if (!info.enabled) {
            return null
        }
        val label = try {
            pm.getApplicationLabel(info).toString()
        } catch (_: Exception) {
            null
        }
        return mapOf(
            "package" to browser,
            "label" to label,
            "state" to if (hasSwitch) readSwitch(context, browser) else BROWSER_SWITCH_UNKNOWN,
            "settings" to (hasSwitch && resolves(pm, browser)),
        )
    }

    /** The switch as the browser's provider says it; unknown on anything unexpected. */
    private fun readSwitch(context: Context, browser: String): Int = try {
        context.contentResolver.query(
            Uri.parse(thirdPartyModeUri(browser)),
            arrayOf(THIRD_PARTY_MODE_COLUMN),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) {
                BROWSER_SWITCH_UNKNOWN
            } else {
                val column = cursor.getColumnIndex(THIRD_PARTY_MODE_COLUMN)
                if (column < 0 || cursor.isNull(column)) {
                    BROWSER_SWITCH_UNKNOWN
                } else {
                    thirdPartyModeState(cursor.getInt(column))
                }
            }
        } ?: BROWSER_SWITCH_UNKNOWN
    } catch (error: Exception) {
        // No such provider, not allowed (SecurityException), a value of
        // another type: nothing is known.
        Log.w(TAG, "Reading a browser's autofill switch failed: ${error.javaClass.simpleName}")
        BROWSER_SWITCH_UNKNOWN
    }

    private fun settingsIntent(browser: String): Intent =
        Intent(Intent.ACTION_APPLICATION_PREFERENCES)
            .addCategory(Intent.CATEGORY_DEFAULT)
            .addCategory(Intent.CATEGORY_APP_BROWSER)
            .addCategory(Intent.CATEGORY_PREFERENCE)
            .setPackage(browser)

    private fun resolves(pm: PackageManager, browser: String): Boolean = try {
        @Suppress("DEPRECATION")
        pm.resolveActivity(settingsIntent(browser), 0)?.activityInfo?.packageName == browser
    } catch (_: Exception) {
        false
    }

    private fun open(activity: Activity, browser: String): Boolean {
        if (!resolves(activity.packageManager, browser)) {
            return false
        }
        return try {
            activity.startActivity(settingsIntent(browser))
            true
        } catch (error: Exception) {
            Log.w(TAG, "Opening a browser's settings failed: ${error.javaClass.simpleName}")
            false
        }
    }
}
