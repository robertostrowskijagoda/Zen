package com.roj.zen

import android.app.Application
import android.content.Context
import android.net.wifi.WifiManager
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

class ZenApplication : Application() {
    private var multicastLock: WifiManager.MulticastLock? = null

    /** The background service's engine (the service runs one at a time). */
    private var taskEngine: FlutterEngine? = null

    private val backgroundTaskLifecycleListener =
        object : FlutterForegroundTaskLifecycleListener {
            override fun onEngineCreate(flutterEngine: FlutterEngine?) {
                if (flutterEngine == null) {
                    return
                }
                GeneratedPluginRegistrant.registerWith(flutterEngine)
                ZenCallBridge.register(flutterEngine, this@ZenApplication)
                // A new task replaces the old one.
                taskEngine?.let { forgetTaskEngine(it) }
                taskEngine = flutterEngine
                // People nearby and the power-button alarm keep working while
                // the app is closed (§15, §16.3). No Activity here: the
                // nearby bridge only reports missing permissions.
                ZenNearbyBridge.registerBackground(flutterEngine, this@ZenApplication)
                ZenAlarmShortcut.register(flutterEngine, this@ZenApplication, background = true)
            }

            override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

            override fun onTaskRepeatEvent() {}

            override fun onTaskDestroy() {}

            override fun onEngineWillDestroy() {
                taskEngine?.let { forgetTaskEngine(it) }
                taskEngine = null
            }
        }

    private fun forgetTaskEngine(engine: FlutterEngine) {
        ZenNearbyBridge.unregister(engine)
        ZenAlarmShortcut.unregister(engine)
    }

    override fun onCreate() {
        super.onCreate()
        acquireMulticastLock()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(backgroundTaskLifecycleListener)
    }

    private fun acquireMulticastLock() {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val lock = wifi?.createMulticastLock("zen-yggdrasil") ?: return
        lock.setReferenceCounted(false)
        lock.acquire()
        multicastLock = lock
    }
}
