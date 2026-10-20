package com.roj.zen

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The Wi-Fi multicast lock (`zen/multicast`) for LAN discovery (§5.1 item 6):
 * Android delivers multicast on Wi-Fi only to apps holding a
 * `WifiManager.MulticastLock`, and holding one costs battery, so it is held
 * only while the setting "Szukaj znajomych w tej samej sieci Wi-Fi" is on.
 * Dart sets it at every node start (`setHeld`). One lock for the process:
 * the app's and the background service's engines both use it.
 */
object ZenMulticastLock {
    private const val TAG = "ZenMulticast"
    private var lock: WifiManager.MulticastLock? = null

    fun register(engine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, "zen/multicast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setHeld" -> result.success(
                        setHeld(appContext, call.argument<Boolean>("held") ?: false),
                    )
                    else -> result.notImplemented()
                }
            }
    }

    @Synchronized
    fun setHeld(context: Context, held: Boolean): Boolean {
        return try {
            if (held) {
                val current = lock ?: run {
                    val wifi = context.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                        ?: return false
                    wifi.createMulticastLock("zen-lan-discovery").apply {
                        setReferenceCounted(false)
                    }
                }
                lock = current
                if (!current.isHeld) {
                    current.acquire()
                }
            } else {
                lock?.let { if (it.isHeld) it.release() }
            }
            true
        } catch (error: RuntimeException) {
            Log.w(TAG, "setHeld($held) failed", error)
            false
        }
    }
}
