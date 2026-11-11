package com.roj.zen

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.autofill.Dataset
import android.util.Log
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * The autofill request between [ZenAutofillActivity] and the picker in
 * Dart (`zen/autofill`, the app's engine only; password_autofill_bridge.dart).
 *
 * At most one request is open: a newer one cancels the older. It holds the
 * requesting app's package and name, the page's address when a known
 * browser reported it, and the two fields' ids; never a password. Dart is
 * told `changed` whenever a request opens or ends, and asks:
 * * `pending` → {id, package, label, webDomain, webScheme, username} or null;
 * * `fill` {id, login, password}: fills the form of the open request [id]
 *   with exactly that login and password, ends it and goes back to the
 *   app; false when [id] is no longer open (nothing is filled then);
 * * `cancel` {id, back}: ends the request with nothing filled (back: return
 *   to the app, when the person closed the picker);
 * * `guard` {on}: drops touches that come through another app's window
 *   drawn over Zen while the picker is up;
 * * `status` → {supported, enabled}; `openSettings`: Android's page to pick
 *   the autofill service (Zen preselected), or the settings when Zen is it.
 *
 * Everything runs on the main thread (the channel's and the activity's).
 * A request left open for [TIMEOUT_MS] is cancelled. Nothing about the
 * app, the page or the entry goes to the log.
 */
object ZenAutofillBridge {
    private const val TAG = "ZenAutofill"
    private const val CHANNEL = "zen/autofill"

    /** How long the person has to unlock Zen and pick an entry. */
    private const val TIMEOUT_MS = 60_000L

    /** One open autofill request (no values). */
    class Request(
        val packageName: String,
        val appLabel: String?,
        val webDomain: String?,
        val webScheme: String?,
        val usernameId: AutofillId?,
        val passwordId: AutofillId,
    ) {
        val id: String = UUID.randomUUID().toString()
    }

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var channelEngine: FlutterEngine? = null
    private var request: Request? = null
    private var host: Activity? = null
    private val timeout = Runnable { end(null) }

    // ---- the activity's side ----

    /** [activity] took [next]: any older request ends with nothing filled. */
    fun open(activity: Activity, next: Request) {
        end(null, notify = false)
        request = next
        host = activity
        main.postDelayed(timeout, TIMEOUT_MS)
        changed()
    }

    /** [activity]'s request ends with nothing filled. */
    fun cancel(activity: Activity) {
        if (host === activity) {
            end(null)
        } else if (!activity.isFinishing) {
            activity.finish()
        }
    }

    /** [activity] is gone: its request with it. */
    fun gone(activity: Activity) {
        if (host === activity) {
            main.removeCallbacks(timeout)
            request = null
            host = null
            changed()
        }
    }

    /**
     * Ends the open request: [dataset] fills the form, null fills nothing.
     * The request and the activity are let go of either way.
     */
    private fun end(dataset: Dataset?, notify: Boolean = true) {
        main.removeCallbacks(timeout)
        val activity = host
        val had = request != null
        request = null
        host = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity is ZenAutofillActivity) {
            activity.complete(dataset)
        } else if (activity != null && !activity.isFinishing) {
            activity.finish()
        }
        if (had && notify) {
            changed()
        }
    }

    private fun changed() {
        try {
            channel?.invokeMethod("changed", null)
        } catch (error: Exception) {
            Log.w(TAG, "Telling the app about autofill failed: ${error.javaClass.simpleName}")
        }
    }

    // ---- the engine's side ----

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
                    "pending" -> result.success(describe(request))
                    "fill" -> {
                        val id = call.argument<String>("id")
                        val login = call.argument<String>("login") ?: ""
                        val password = call.argument<String>("password") ?: ""
                        val open = request
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P ||
                            open == null || id == null || open.id != id
                        ) {
                            result.success(false)
                        } else {
                            val dataset = filled(activity, open, login, password)
                            end(dataset)
                            // Back to the app whose form it was.
                            activity.moveTaskToBack(true)
                            result.success(dataset != null)
                        }
                    }
                    "cancel" -> {
                        val id = call.argument<String>("id")
                        val back = call.argument<Boolean>("back") ?: false
                        val open = request
                        if (open != null && open.id == id) {
                            end(null)
                            if (back) {
                                activity.moveTaskToBack(true)
                            }
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "guard" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        activity.window?.decorView?.filterTouchesWhenObscured = on
                        result.success(true)
                    }
                    "status" -> result.success(status(activity))
                    "openSettings" -> result.success(openSettings(activity))
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                Log.w(TAG, "Autofill call failed: ${error.javaClass.simpleName}")
                // A fill that failed fills nothing; the request ends.
                if (call.method == "fill") {
                    end(null)
                }
                result.success(false)
            }
        }
    }

    private fun describe(open: Request?): Map<String, Any?>? = open?.let {
        mapOf(
            "id" to it.id,
            "package" to it.packageName,
            "label" to it.appLabel,
            "webDomain" to it.webDomain,
            "webScheme" to it.webScheme,
            "username" to (it.usernameId != null),
        )
    }

    /**
     * The answer that fills [open]'s fields with [login] and [password]:
     * only the fields the form had, only values that are not empty. Null
     * when nothing would be filled.
     */
    @RequiresApi(Build.VERSION_CODES.P)
    @Suppress("DEPRECATION")
    private fun filled(activity: Activity, open: Request, login: String, password: String): Dataset? {
        val usernameId = open.usernameId
        val fillLogin = usernameId != null && login.isNotEmpty()
        val fillPassword = password.isNotEmpty()
        if (!fillLogin && !fillPassword) {
            return null
        }
        // Never shown (the framework fills it at once), but a dataset needs one.
        val presentation = RemoteViews(activity.packageName, android.R.layout.simple_list_item_1)
        val builder = Dataset.Builder(presentation)
        if (fillLogin) {
            builder.setValue(usernameId!!, AutofillValue.forText(login))
        }
        if (fillPassword) {
            builder.setValue(open.passwordId, AutofillValue.forText(password))
        }
        return builder.build()
    }

    private fun status(activity: Activity): Map<String, Boolean> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return mapOf("supported" to false, "enabled" to false)
        }
        val manager = activity.getSystemService(AutofillManager::class.java)
        val supported = manager != null && manager.isAutofillSupported
        return mapOf(
            "supported" to supported,
            "enabled" to (supported && manager!!.hasEnabledAutofillServices()),
        )
    }

    private fun openSettings(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return false
        }
        val manager = activity.getSystemService(AutofillManager::class.java)
        // The picker page does nothing when Zen is already the service:
        // the settings open instead, where it is switched off.
        val intent = if (manager != null && manager.hasEnabledAutofillServices()) {
            Intent(Settings.ACTION_SETTINGS)
        } else {
            Intent(
                Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE,
                Uri.parse("package:${activity.packageName}"),
            )
        }
        return try {
            activity.startActivity(intent)
            true
        } catch (error: Exception) {
            Log.w(TAG, "Opening the autofill settings failed: ${error.javaClass.simpleName}")
            false
        }
    }
}
