package com.roj.zen

import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Films of the "Filmy" section made small enough to travel between friends
 * (`zen/video`, see video_compressor.dart): the phone's own H.264 encoder
 * (MediaCodec) re-encodes the picture at most 720p and at the asked bit
 * rate, cut to the asked start and end; the sound (AAC) is copied as it is,
 * interleaved with the picture so the film can play while it downloads.
 * Decoded frames go through a GL surface, which scales them. No library
 * beyond the platform.
 *
 *  - `isAvailable`: true;
 *  - `compress` {input, output, startMs, endMs (-1: to the end),
 *    maxShortSide, videoBitrate, audioBitrate} → {durationMs, width,
 *    height, bytes}; `progress` {fraction} is called back meanwhile;
 *  - `cancel`: the running compression fails with "cancelled";
 *  - `thumbnail` {input, atMs, maxSide} → JPEG bytes or null.
 */
object ZenVideoBridge {
    private const val TAG = "ZenVideo"
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val cancelled = AtomicBoolean(false)
    private var channel: MethodChannel? = null

    fun register(engine: FlutterEngine, context: Context) {
        val c = MethodChannel(engine.dartExecutor.binaryMessenger, "zen/video")
        channel = c
        c.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(true)
                "cancel" -> {
                    cancelled.set(true)
                    result.success(null)
                }
                "compress" -> {
                    val input = call.argument<String>("input")
                    val output = call.argument<String>("output")
                    if (input == null || output == null) {
                        result.error("failed", "input and output are needed", null)
                        return@setMethodCallHandler
                    }
                    val startMs = (call.argument<Number>("startMs") ?: 0).toLong()
                    val endMs = (call.argument<Number>("endMs") ?: -1).toLong()
                    val maxShort = (call.argument<Number>("maxShortSide") ?: 720).toInt()
                    val videoBitrate = (call.argument<Number>("videoBitrate") ?: 2_500_000).toInt()
                    val audioBitrate = (call.argument<Number>("audioBitrate") ?: 128_000).toInt()
                    cancelled.set(false)
                    worker.execute {
                        try {
                            val out = Transcoder(
                                input,
                                output,
                                startMs * 1000,
                                if (endMs < 0) Long.MAX_VALUE else endMs * 1000,
                                maxShort,
                                videoBitrate,
                                audioBitrate,
                                cancelled,
                            ) { fraction -> progress(fraction) }.run()
                            main.post { result.success(out) }
                        } catch (_: CancelledException) {
                            File(output).delete()
                            main.post { result.error("cancelled", "cancelled", null) }
                        } catch (error: Throwable) {
                            Log.w(TAG, "Compressing a film failed", error)
                            File(output).delete()
                            main.post { result.error("failed", error.message ?: error.toString(), null) }
                        }
                    }
                }
                "thumbnail" -> {
                    val input = call.argument<String>("input")
                    val atMs = (call.argument<Number>("atMs") ?: 0).toLong()
                    val maxSide = (call.argument<Number>("maxSide") ?: 480).toInt()
                    if (input == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        val bytes = try {
                            thumbnail(input, atMs, maxSide)
                        } catch (error: Throwable) {
                            Log.w(TAG, "A film frame failed", error)
                            null
                        }
                        main.post { result.success(bytes) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private var lastProgressAt = 0L

    private fun progress(fraction: Double) {
        val now = System.currentTimeMillis()
        if (now - lastProgressAt < 250 && fraction < 1.0) {
            return
        }
        lastProgressAt = now
        main.post {
            channel?.invokeMethod("progress", mapOf("fraction" to fraction.coerceIn(0.0, 1.0)))
        }
    }

    private fun thumbnail(input: String, atMs: Long, maxSide: Int): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(input)
            val frame = retriever.getFrameAtTime(
                atMs * 1000,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: return null
            val longest = max(frame.width, frame.height)
            val scaled = if (longest > maxSide) {
                val s = maxSide.toFloat() / longest
                Bitmap.createScaledBitmap(
                    frame,
                    max(1, (frame.width * s).roundToInt()),
                    max(1, (frame.height * s).roundToInt()),
                    true,
                )
            } else {
                frame
            }
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
            return out.toByteArray()
        } finally {
            retriever.release()
        }
    }
}

private class CancelledException : Exception()

/** The picture size a film is compressed to: video_compressor.dart's scaledVideoSize. */
internal fun scaledVideoSize(width: Int, height: Int, maxShortSide: Int): Pair<Int, Int> {
    if (width <= 0 || height <= 0) {
        return Pair(0, 0)
    }
    val short = min(width, height)
    if (short <= maxShortSide) {
        return Pair(width and 1.inv(), height and 1.inv())
    }
    val scale = maxShortSide.toDouble() / short
    fun even(v: Double) = max(2, v.roundToInt() and 1.inv())
    return Pair(even(width * scale), even(height * scale))
}

/** One compression (see [ZenVideoBridge]); runs on the worker thread. */
private class Transcoder(
    private val input: String,
    private val output: String,
    private val startUs: Long,
    private val endUsAsked: Long,
    private val maxShortSide: Int,
    private val videoBitrate: Int,
    private val audioBitrate: Int,
    private val cancelled: AtomicBoolean,
    private val onProgress: (Double) -> Unit,
) {
    private val timeoutUs = 10_000L

    fun run(): Map<String, Any> {
        val videoExtractor = MediaExtractor()
        val audioExtractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var inputSurface: CodecInputSurface? = null
        var outputSurface: DecoderOutputSurface? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        try {
            videoExtractor.setDataSource(input)
            val videoTrack = trackOf(videoExtractor, "video/")
            require(videoTrack >= 0) { "no picture in the film" }
            videoExtractor.selectTrack(videoTrack)
            val inFormat = videoExtractor.getTrackFormat(videoTrack)
            val width = inFormat.getInteger(MediaFormat.KEY_WIDTH)
            val height = inFormat.getInteger(MediaFormat.KEY_HEIGHT)
            val rotation = rotationOf(inFormat)
            val durationUs = if (inFormat.containsKey(MediaFormat.KEY_DURATION)) {
                inFormat.getLong(MediaFormat.KEY_DURATION)
            } else {
                Long.MAX_VALUE
            }
            val endUs = min(endUsAsked, durationUs)
            val spanUs = max(1L, (if (endUs == Long.MAX_VALUE) durationUs else endUs) - startUs)

            audioExtractor.setDataSource(input)
            val audioTrack = trackOf(audioExtractor, "audio/mp4a")
            var audioFormat: MediaFormat? = null
            var audioOverBudget = 0
            if (audioTrack >= 0) {
                audioExtractor.selectTrack(audioTrack)
                audioFormat = audioExtractor.getTrackFormat(audioTrack)
                if (audioFormat.containsKey(MediaFormat.KEY_BIT_RATE)) {
                    audioOverBudget = max(0, audioFormat.getInteger(MediaFormat.KEY_BIT_RATE) - audioBitrate)
                }
                audioExtractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }

            val (outW, outH) = scaledVideoSize(width, height, maxShortSide)
            val outFormat = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outW, outH)
            outFormat.setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
            // Copied sound richer than planned takes its share from the picture.
            outFormat.setInteger(MediaFormat.KEY_BIT_RATE, max(400_000, videoBitrate - audioOverBudget))
            outFormat.setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            outFormat.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            encoder = enc
            enc.configure(outFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val inSurf = CodecInputSurface(enc.createInputSurface())
            inputSurface = inSurf
            inSurf.makeCurrent()
            enc.start()

            val outSurf = DecoderOutputSurface()
            outputSurface = outSurf
            val mime = inFormat.getString(MediaFormat.KEY_MIME)!!
            val dec = MediaCodec.createDecoderByType(mime)
            decoder = dec
            dec.configure(inFormat, outSurf.surface, null, 0)
            dec.start()

            val mux = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mux
            mux.setOrientationHint(rotation)
            var muxVideo = -1
            var muxAudio = -1

            videoExtractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val info = MediaCodec.BufferInfo()
            val audioBuffer = ByteBuffer.allocate(256 * 1024)
            val audioInfo = MediaCodec.BufferInfo()
            var audioDone = audioTrack < 0
            var inputDone = false
            var decoderDone = false
            var encoderDone = false
            var lastVideoUs = 0L

            /** Sound up to [untilUs] (of the output), copied as it is. */
            fun copyAudio(untilUs: Long) {
                while (!audioDone && muxAudio >= 0) {
                    val t = audioExtractor.sampleTime
                    if (t < 0 || t > endUs) {
                        audioDone = true
                        return
                    }
                    if (t - startUs > untilUs) {
                        return
                    }
                    val size = audioExtractor.readSampleData(audioBuffer, 0)
                    if (size < 0) {
                        audioDone = true
                        return
                    }
                    if (t >= startUs) {
                        audioInfo.set(0, size, t - startUs, MediaCodec.BUFFER_FLAG_KEY_FRAME)
                        mux.writeSampleData(muxAudio, audioBuffer, audioInfo)
                    }
                    audioExtractor.advance()
                }
            }

            while (!encoderDone) {
                if (cancelled.get()) {
                    throw CancelledException()
                }
                if (!inputDone) {
                    val index = dec.dequeueInputBuffer(timeoutUs)
                    if (index >= 0) {
                        val buffer = dec.getInputBuffer(index)!!
                        val size = videoExtractor.readSampleData(buffer, 0)
                        val t = videoExtractor.sampleTime
                        if (size < 0 || t < 0 || t > endUs) {
                            dec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            dec.queueInputBuffer(index, 0, size, t, 0)
                            videoExtractor.advance()
                        }
                    }
                }
                // The encoder's output first: it frees room for more frames.
                var encoderBusy = true
                while (encoderBusy) {
                    val index = enc.dequeueOutputBuffer(info, timeoutUs)
                    when {
                        index == MediaCodec.INFO_TRY_AGAIN_LATER -> encoderBusy = false
                        index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            check(!muxerStarted) { "the format changed twice" }
                            muxVideo = mux.addTrack(enc.outputFormat)
                            if (audioFormat != null) {
                                muxAudio = mux.addTrack(audioFormat)
                            }
                            mux.start()
                            muxerStarted = true
                        }
                        index >= 0 -> {
                            val data = enc.getOutputBuffer(index)!!
                            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                                info.size = 0
                            }
                            if (info.size > 0 && muxerStarted) {
                                data.position(info.offset)
                                data.limit(info.offset + info.size)
                                copyAudio(info.presentationTimeUs)
                                mux.writeSampleData(muxVideo, data, info)
                                lastVideoUs = max(lastVideoUs, info.presentationTimeUs)
                                onProgress(info.presentationTimeUs.toDouble() / spanUs)
                            }
                            enc.releaseOutputBuffer(index, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                encoderDone = true
                                encoderBusy = false
                            }
                        }
                    }
                }
                if (!decoderDone) {
                    val index = dec.dequeueOutputBuffer(info, timeoutUs)
                    if (index >= 0) {
                        val t = info.presentationTimeUs
                        val render = info.size > 0 && t >= startUs && t <= endUs
                        dec.releaseOutputBuffer(index, render)
                        if (render) {
                            outSurf.awaitNewImage()
                            outSurf.drawImage(outW, outH)
                            inSurf.setPresentationTime((t - startUs) * 1000)
                            inSurf.swapBuffers()
                        }
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            decoderDone = true
                            enc.signalEndOfInputStream()
                        }
                    }
                }
            }
            copyAudio(Long.MAX_VALUE)
            onProgress(1.0)
            check(muxerStarted) { "no frames came out" }
            mux.stop()
            muxerStarted = false
            val turned = rotation == 90 || rotation == 270
            return mapOf(
                "durationMs" to lastVideoUs / 1000,
                "width" to if (turned) outH else outW,
                "height" to if (turned) outW else outH,
                "bytes" to File(output).length(),
            )
        } finally {
            try {
                decoder?.stop()
            } catch (_: Exception) {
            }
            decoder?.release()
            try {
                encoder?.stop()
            } catch (_: Exception) {
            }
            encoder?.release()
            outputSurface?.release()
            inputSurface?.release()
            if (muxerStarted) {
                try {
                    muxer?.stop()
                } catch (_: Exception) {
                }
            }
            try {
                muxer?.release()
            } catch (_: Exception) {
            }
            videoExtractor.release()
            audioExtractor.release()
        }
    }

    private fun trackOf(extractor: MediaExtractor, prefix: String): Int {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith(prefix)) {
                return i
            }
        }
        return -1
    }

    private fun rotationOf(format: MediaFormat): Int {
        val key = "rotation-degrees"
        if (format.containsKey(key)) {
            return format.getInteger(key)
        }
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(input)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        } catch (_: Exception) {
            0
        } finally {
            retriever.release()
        }
    }
}

/** The encoder's input surface as an EGL window (recordable). */
private class CodecInputSurface(private val surface: Surface) {
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    init {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display != EGL14.EGL_NO_DISPLAY) { "no EGL display" }
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "EGL did not start" }
        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] > 0) {
            "no EGL config"
        }
        context = EGL14.eglCreateContext(
            display,
            configs[0],
            EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
            0,
        )
        check(context != EGL14.EGL_NO_CONTEXT) { "no EGL context" }
        eglSurface = EGL14.eglCreateWindowSurface(display, configs[0], surface, intArrayOf(EGL14.EGL_NONE), 0)
        check(eglSurface != EGL14.EGL_NO_SURFACE) { "no EGL surface" }
    }

    fun makeCurrent() {
        check(EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) { "EGL make current failed" }
    }

    fun swapBuffers() {
        EGL14.eglSwapBuffers(display, eglSurface)
    }

    fun setPresentationTime(nanos: Long) {
        EGLExt.eglPresentationTimeANDROID(display, eglSurface, nanos)
    }

    fun release() {
        if (display != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, eglSurface)
            EGL14.eglDestroyContext(display, context)
            EGL14.eglReleaseThread()
            EGL14.eglTerminate(display)
        }
        surface.release()
        display = EGL14.EGL_NO_DISPLAY
    }

    companion object {
        private const val EGL_RECORDABLE_ANDROID = 0x3142
    }
}

/** Where the decoder draws: a GL texture that is drawn again, scaled, into the encoder. */
private class DecoderOutputSurface : SurfaceTexture.OnFrameAvailableListener {
    private val lock = Object()
    private var frameAvailable = false
    private val texture: Int
    private val surfaceTexture: SurfaceTexture
    val surface: Surface
    private val program: Int
    private val matrix = FloatArray(16)
    private val vertices: FloatBuffer

    init {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        texture = ids[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        surfaceTexture = SurfaceTexture(texture)
        surfaceTexture.setOnFrameAvailableListener(this)
        surface = Surface(surfaceTexture)
        program = buildProgram()
        // x, y, u, v of a full-screen quad.
        val quad = floatArrayOf(
            -1f, -1f, 0f, 0f,
            1f, -1f, 1f, 0f,
            -1f, 1f, 0f, 1f,
            1f, 1f, 1f, 1f,
        )
        vertices = ByteBuffer.allocateDirect(quad.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        vertices.put(quad).position(0)
    }

    override fun onFrameAvailable(st: SurfaceTexture?) {
        synchronized(lock) {
            frameAvailable = true
            lock.notifyAll()
        }
    }

    fun awaitNewImage() {
        synchronized(lock) {
            val until = System.currentTimeMillis() + 2500
            while (!frameAvailable) {
                val left = until - System.currentTimeMillis()
                check(left > 0) { "no frame from the decoder" }
                lock.wait(left)
            }
            frameAvailable = false
        }
        surfaceTexture.updateTexImage()
    }

    fun drawImage(width: Int, height: Int) {
        surfaceTexture.getTransformMatrix(matrix)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        val position = GLES20.glGetAttribLocation(program, "aPosition")
        val coord = GLES20.glGetAttribLocation(program, "aCoord")
        vertices.position(0)
        GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 16, vertices)
        GLES20.glEnableVertexAttribArray(position)
        vertices.position(2)
        GLES20.glVertexAttribPointer(coord, 2, GLES20.GL_FLOAT, false, 16, vertices)
        GLES20.glEnableVertexAttribArray(coord)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uMatrix"), 1, false, matrix, 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glFinish()
    }

    fun release() {
        GLES20.glDeleteProgram(program)
        surface.release()
        surfaceTexture.release()
    }

    private fun buildProgram(): Int {
        val vertex = """
            attribute vec4 aPosition;
            attribute vec4 aCoord;
            uniform mat4 uMatrix;
            varying vec2 vCoord;
            void main() {
              gl_Position = aPosition;
              vCoord = (uMatrix * aCoord).xy;
            }
        """.trimIndent()
        val fragment = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vCoord;
            uniform samplerExternalOES sTexture;
            void main() {
              gl_FragColor = texture2D(sTexture, vCoord);
            }
        """.trimIndent()
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, vertex))
        GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, fragment))
        GLES20.glLinkProgram(p)
        val linked = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, linked, 0)
        check(linked[0] == GLES20.GL_TRUE) { "the GL program did not link" }
        return p
    }

    private fun shader(type: Int, source: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, source)
        GLES20.glCompileShader(s)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
        check(ok[0] == GLES20.GL_TRUE) { "a GL shader did not compile" }
        return s
    }
}
