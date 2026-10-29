package com.roj.zen

import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioSwitchManager
import io.flutter.embedding.engine.FlutterEngine

/**
 * flutter_webrtc keeps process-wide state in statics
 * (`FlutterWebRTCPlugin.sharedSingleton`, `AudioSwitchManager.instance`),
 * which every engine that registers the plugin replaces, and which an
 * engine that lets go of it stops. The background service's engine
 * registered it too: when the service started or ended during a call (the
 * app taking the node over), the call's peer connection was left with the
 * service's factory and its audio manager stopped, and the next frame
 * cryptor crashed the app natively (SIGSEGV in
 * `FrameCryptorFactory.nativeCreateFrameCryptorForRtpSender`).
 *
 * Calls run only in the app's engine, so the service's engine never keeps
 * the plugin, and the app's state is put back.
 */
object ZenWebRtcGuard {
    private const val TAG = "ZenWebRtcGuard"
    private var appPlugin: FlutterWebRTCPlugin? = null
    private var appAudio: AudioSwitchManager? = null

    /** The app's engine registered its plugins: its WebRTC state is the one to keep. */
    fun appEngineReady(engine: FlutterEngine) {
        appPlugin = engine.plugins.get(FlutterWebRTCPlugin::class.java) as? FlutterWebRTCPlugin
        appAudio = AudioSwitchManager.instance
    }

    /** The app's engine is gone: nothing of it to put back any more. */
    fun appEngineGone(engine: FlutterEngine) {
        if (engine.plugins.get(FlutterWebRTCPlugin::class.java) === appPlugin) {
            appPlugin = null
            appAudio = null
        }
    }

    /** A background engine: takes flutter_webrtc out of it and restores the app's state. */
    fun keepOutOf(engine: FlutterEngine) {
        try {
            if (engine.plugins.has(FlutterWebRTCPlugin::class.java)) {
                engine.plugins.remove(FlutterWebRTCPlugin::class.java)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Taking WebRTC out of the background engine failed", error)
        }
        appPlugin?.let { FlutterWebRTCPlugin.sharedSingleton = it }
        appAudio?.let { AudioSwitchManager.instance = it }
    }
}
