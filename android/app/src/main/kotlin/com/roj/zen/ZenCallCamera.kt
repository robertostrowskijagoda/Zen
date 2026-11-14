package com.roj.zen

import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CaptureRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import android.view.Surface
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import java.lang.reflect.Field

/**
 * The auto-exposure frame-rate range of a call's camera.
 *
 * WebRTC's Android camera (`Camera2Session`) asks the camera for the range
 * with the lowest floor it offers, 7-30 on most phones, so that the frame
 * rate follows the light. In poor light the auto-exposure then goes down
 * to that floor: a call's picture came at 5-6 frames a second, each
 * smeared by any movement. Neither WebRTC nor flutter_webrtc lets an app
 * choose the range, so once the camera of a call runs its range is pinned
 * here to the one Zen chose from what the camera offers
 * (`chooseCameraFrameRateRange` in call_video_quality.dart): the
 * session's repeating request is made again as `Camera2Session` makes it,
 * with only the range changed. flutter_webrtc reaches the same fields the
 * same way for its torch, zoom and focus (`CameraUtils`).
 *
 * The fields are private to flutter_webrtc and WebRTC: when an update
 * renames them, nothing is pinned, the call goes on with the camera's own
 * range and the technical log says why.
 */
object ZenCallCamera {
    private const val TAG = "ZenCallCamera"

    /** How often, and how far apart, a camera still being set up is looked at again. */
    private const val LOOKS = 15
    private const val LOOK_EVERY_MS = 200L

    private val mainHandler = Handler(Looper.getMainLooper())

    /** The parts of a running `Camera2Session` the request is made of. */
    private class Session(
        val captureSession: CameraCaptureSession,
        val cameraDevice: CameraDevice,
        val characteristics: CameraCharacteristics,
        val surface: Surface,
        val handler: Handler,
        val unitFactor: Int,
    )

    /**
     * The ranges the camera of the call's video track [trackId] offers and
     * the one it runs at, in frames a second:
     * `{ranges: [[min, max], …], current: [min, max]}`, or `{error: why}`.
     * Answers on the main thread once the camera's session is set up (it
     * is looked at again for up to three seconds).
     */
    fun frameRates(trackId: String, reply: (Map<String, Any>) -> Unit) {
        withSession(trackId, LOOKS) { session, error ->
            if (session == null) {
                reply(mapOf("error" to (error ?: "no camera session")))
                return@withSession
            }
            val raw = rawRanges(session.characteristics)
            reply(
                mapOf(
                    "ranges" to raw.map {
                        val fps = CallCameraRanges.toFps(it.lower, it.upper, session.unitFactor)
                        listOf(fps.first, fps.second)
                    },
                    "current" to (currentRange(trackId)?.let { listOf(it.first, it.second) }
                        ?: emptyList<Int>()),
                ),
            )
        }
    }

    /**
     * Pins the auto-exposure of [trackId]'s camera to the offered range
     * that is [minFps]-[maxFps] in frames a second. Replies `"pinned"` or
     * why not, on the main thread.
     */
    fun pinFrameRate(trackId: String, minFps: Int, maxFps: Int, reply: (String) -> Unit) {
        withSession(trackId, LOOKS) { session, error ->
            if (session == null) {
                reply(error ?: "no camera session")
                return@withSession
            }
            val raw = rawRanges(session.characteristics).firstOrNull {
                CallCameraRanges.toFps(it.lower, it.upper, session.unitFactor) == Pair(minFps, maxFps)
            }
            if (raw == null) {
                reply("the camera does not offer $minFps-$maxFps")
                return@withSession
            }
            session.handler.post {
                val outcome = try {
                    val builder = session.cameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                    builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, raw)
                    builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                    builder.set(CaptureRequest.CONTROL_AE_LOCK, false)
                    chooseStabilization(builder, session.characteristics)
                    chooseFocus(builder, session.characteristics)
                    builder.addTarget(session.surface)
                    session.captureSession.setRepeatingRequest(builder.build(), null, session.handler)
                    "pinned"
                } catch (error: Exception) {
                    // A camera closed meanwhile (switched, call ended).
                    Log.w(TAG, "Pinning the camera's frame rate failed", error)
                    "refused: ${error.javaClass.simpleName}"
                }
                mainHandler.post { reply(outcome) }
            }
        }
    }

    /** As `Camera2Session.chooseStabilizationMode`: optical first, else the camera's own. */
    private fun chooseStabilization(builder: CaptureRequest.Builder, characteristics: CameraCharacteristics) {
        val optical = characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
        if (optical != null && optical.contains(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON)) {
            builder.set(
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON,
            )
            builder.set(
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
            )
            return
        }
        val video = characteristics.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
        if (video != null && video.contains(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)) {
            builder.set(
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON,
            )
            builder.set(
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF,
            )
        }
    }

    /** As `Camera2Session.chooseFocusMode`: continuous focus for video where there is one. */
    private fun chooseFocus(builder: CaptureRequest.Builder, characteristics: CameraCharacteristics) {
        val modes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: return
        if (modes.contains(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)) {
            builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
        }
    }

    private fun rawRanges(characteristics: CameraCharacteristics): List<Range<Int>> =
        characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)?.toList()
            ?: emptyList()

    /** The range the session asked for (its `captureFormat`), in frames a second. */
    private fun currentRange(trackId: String): Pair<Int, Int>? = try {
        val session = cameraSession(trackId)
        val format = session?.let { field(it, "captureFormat") }
        val rate = format?.let { field(it, "framerate") }
        if (rate == null) {
            null
        } else {
            // In thousandths of a frame, whatever unit the camera reports in.
            Pair((field(rate, "min") as Int) / 1000, (field(rate, "max") as Int) / 1000)
        }
    } catch (error: Exception) {
        null
    }

    /**
     * [use] with the configured session of [trackId]'s camera, or with why
     * there is none. A session still opening is looked at again [looks]
     * times, [LOOK_EVERY_MS] apart. Always on the main thread.
     */
    private fun withSession(trackId: String, looks: Int, use: (Session?, String?) -> Unit) {
        val session: Session?
        try {
            session = readSession(trackId)
        } catch (error: Exception) {
            Log.w(TAG, "Reading the call camera failed", error)
            use(null, "unreadable: ${error.message ?: error.javaClass.simpleName}")
            return
        }
        if (session != null) {
            use(session, null)
            return
        }
        if (looks <= 0) {
            use(null, "the camera's session never came up")
            return
        }
        mainHandler.postDelayed({ withSession(trackId, looks - 1, use) }, LOOK_EVERY_MS)
    }

    /** The configured `Camera2Session` of [trackId], null while it is not set up yet. */
    private fun readSession(trackId: String): Session? {
        val session = cameraSession(trackId) ?: return null
        val captureSession = field(session, "captureSession") as? CameraCaptureSession ?: return null
        val cameraDevice = field(session, "cameraDevice") as? CameraDevice ?: return null
        val characteristics = field(session, "cameraCharacteristics") as? CameraCharacteristics ?: return null
        val surface = field(session, "surface") as? Surface ?: return null
        val handler = field(session, "cameraThreadHandler") as? Handler ?: return null
        val unitFactor = field(session, "fpsUnitFactor") as? Int ?: return null
        return Session(captureSession, cameraDevice, characteristics, surface, handler, unitFactor)
    }

    /** flutter_webrtc's capturer of [trackId] and its current camera session. */
    private fun cameraSession(trackId: String): Any? {
        val plugin = FlutterWebRTCPlugin.sharedSingleton ?: return null
        val handler = field(plugin, "methodCallHandler") ?: return null
        val userMedia = field(handler, "getUserMediaImpl") ?: return null
        val info = userMedia.javaClass.getMethod("getCapturerInfo", String::class.java)
            .invoke(userMedia, trackId) ?: return null
        val capturer = info.javaClass.getField("capturer").get(info) ?: return null
        if (capturer.javaClass.name != "org.webrtc.Camera2Capturer") {
            // The older camera API (Camera1Capturer) or a screen: not this.
            throw IllegalStateException("not a Camera2 capturer")
        }
        val session = field(capturer, "currentSession") ?: return null
        return if (session.javaClass.name == "org.webrtc.Camera2Session") session else null
    }

    /** The field [name] of [target] or of one of its superclasses. */
    private fun field(target: Any, name: String): Any? {
        var type: Class<*>? = target.javaClass
        while (type != null) {
            val found: Field? = try {
                type.getDeclaredField(name)
            } catch (_: NoSuchFieldException) {
                null
            }
            if (found != null) {
                found.isAccessible = true
                return found.get(target)
            }
            type = type.superclass
        }
        throw NoSuchFieldException("${target.javaClass.name}.$name")
    }
}

/** The camera's frame-rate ranges in frames a second, kept apart from Android for tests. */
object CallCameraRanges {
    /**
     * [lower]-[upper] as the camera reports it, in frames a second.
     * [unitFactor] is `Camera2Session.fpsUnitFactor`: 1000 for a camera
     * that reports frames a second, 1 for one that reports thousandths.
     */
    fun toFps(lower: Int, upper: Int, unitFactor: Int): Pair<Int, Int> =
        Pair(lower * unitFactor / 1000, upper * unitFactor / 1000)
}
