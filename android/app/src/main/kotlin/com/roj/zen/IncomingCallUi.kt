package com.roj.zen

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.ColorDrawable
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.TextView

/**
 * Incoming-call UI that does not depend on bringing [MainActivity] forward.
 *
 * Unlocked: a SYSTEM_ALERT_WINDOW overlay card over the current app.
 * Locked / screen off: [IncomingCallActivity] as a floating card via
 * showWhenLocked + full-screen intent. Never dismisses the keyguard.
 */
object IncomingCallUi {
    private const val TAG = "ZenIncomingCall"

    private var overlayView: View? = null
    private var overlayRingtone: Ringtone? = null
    private var overlayVibrator: Vibrator? = null

    val isOverlayShowing: Boolean
        get() = overlayView != null

    fun popupWidthPx(context: Context): Int {
        val metrics = context.resources.displayMetrics
        return (metrics.widthPixels * 0.92f).toInt().coerceAtLeast((320 * metrics.density).toInt())
    }

    fun applyPopupWindowSize(window: Window, context: Context) {
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.setLayout(popupWidthPx(context), WindowManager.LayoutParams.WRAP_CONTENT)
        window.setGravity(Gravity.CENTER)
    }

    fun bindCard(
        root: View,
        displayName: String,
        isVideo: Boolean,
        onAccept: () -> Unit,
        onDecline: () -> Unit,
    ) {
        val kind = root.findViewById<TextView>(R.id.incoming_call_kind)
        val subtitle = root.findViewById<TextView>(R.id.incoming_call_subtitle)
        val icon = root.findViewById<ImageView>(R.id.incoming_call_avatar_icon)
        root.findViewById<TextView>(R.id.incoming_call_name).text = displayName
        if (isVideo) {
            kind.setText(R.string.call_kind_video)
            subtitle.setText(R.string.call_subtitle_video)
            icon.setImageResource(android.R.drawable.ic_menu_camera)
        } else {
            kind.setText(R.string.call_kind_audio)
            subtitle.setText(R.string.call_subtitle_audio)
            icon.setImageResource(R.drawable.ic_stat_call)
        }
        root.findViewById<Button>(R.id.incoming_call_accept).setOnClickListener { onAccept() }
        root.findViewById<Button>(R.id.incoming_call_decline).setOnClickListener { onDecline() }
    }

    fun showOverlay(
        context: Context,
        displayName: String,
        isVideo: Boolean,
        onAccept: () -> Unit,
        onDecline: () -> Unit,
    ): Boolean {
        if (overlayView != null) {
            return true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(context)) {
            Log.w(TAG, "Overlay permission missing")
            return false
        }
        return try {
            val themed = ContextThemeWrapper(context, R.style.IncomingCallTheme)
            val view = LayoutInflater.from(themed).inflate(R.layout.incoming_call_popup, null)
            bindCard(view, displayName, isVideo, onAccept, onDecline)
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            }
            val params = WindowManager.LayoutParams(
                popupWidthPx(context),
                WindowManager.LayoutParams.WRAP_CONTENT,
                type,
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT,
            )
            params.gravity = Gravity.CENTER
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.addView(view, params)
            overlayView = view
            startOverlayRinging(context)
            Log.i(TAG, "Overlay shown")
            true
        } catch (error: Exception) {
            Log.e(TAG, "Overlay failed", error)
            overlayView = null
            false
        }
    }

    fun hideOverlay(context: Context) {
        stopOverlayRinging()
        val view = overlayView ?: return
        overlayView = null
        try {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.removeView(view)
        } catch (error: Exception) {
            Log.w(TAG, "Overlay remove failed", error)
        }
    }

    private fun startOverlayRinging(context: Context) {
        try {
            // Zen's own gentle ringtone (res/raw/zen_ringtone.ogg).
            val uri = Uri.parse("android.resource://${context.packageName}/${R.raw.zen_ringtone}")
            val tone = RingtoneManager.getRingtone(context, uri)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                tone?.isLooping = true
            }
            tone?.audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            tone?.play()
            overlayRingtone = tone
        } catch (_: Exception) {
        }
        try {
            val vibe = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            overlayVibrator = vibe
            if (vibe != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibe.vibrate(
                    VibrationEffect.createWaveform(longArrayOf(0, 500, 200, 500, 200, 800), 0),
                )
            }
        } catch (_: Exception) {
        }
    }

    private fun stopOverlayRinging() {
        try {
            overlayRingtone?.stop()
        } catch (_: Exception) {
        }
        overlayRingtone = null
        try {
            overlayVibrator?.cancel()
        } catch (_: Exception) {
        }
        overlayVibrator = null
    }
}
