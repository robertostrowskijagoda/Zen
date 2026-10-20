package com.roj.zen

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.WindowManager
import java.lang.ref.WeakReference

/**
 * Incoming-call card that can sit over the lock screen without bringing the
 * Flutter messenger forward.
 *
 * Must stay opaque: a translucent window over Samsung's keyguard draws the
 * card but does not deliver taps to the accept/decline buttons.
 * Must not call [android.app.KeyguardManager.requestDismissKeyguard] while
 * ringing: that puts the PIN pad on top of those buttons.
 */
class IncomingCallActivity : Activity() {

    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var ringing = false

    override fun onCreate(savedInstanceState: Bundle?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        super.onCreate(savedInstanceState)
        applyLockScreenPresentation()
        instance = WeakReference(this)
        setContentView(R.layout.incoming_call_popup)
        IncomingCallUi.applyPopupWindowSize(window, this)
        bindCard(intent)
        startRinging()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        applyLockScreenPresentation()
        bindCard(intent)
        if (!ringing) {
            startRinging()
        }
    }

    override fun onResume() {
        super.onResume()
        applyLockScreenPresentation()
    }

    override fun onDestroy() {
        stopRinging()
        if (instance?.get() === this) {
            instance = null
        }
        super.onDestroy()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // A ringing call is not dismissed by Back — same as the system dialer.
    }

    private fun applyLockScreenPresentation() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_ALLOW_LOCK_WHILE_SCREEN_ON,
        )
        window.clearFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        window.clearFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
    }

    private fun bindCard(intent: Intent?) {
        val name = intent?.getStringExtra(EXTRA_DISPLAY_NAME)
            ?: ZenCallBridge.pendingDisplayName
        val video = intent?.getBooleanExtra(EXTRA_IS_VIDEO, false)
            ?: ZenCallBridge.pendingIsVideo
        IncomingCallUi.bindCard(
            findViewById(R.id.incoming_call_root),
            displayName = name,
            isVideo = video,
            onAccept = {
                val peer = currentPeerAddress()
                val routeKey = intent?.getStringExtra(EXTRA_ACCEPT_ROUTE)
                    ?: ZenCallBridge.pendingAcceptRouteKey
                acceptAfterUnlock(routeKey, peer)
            },
            onDecline = {
                val peer = currentPeerAddress()
                stopRinging()
                ZenCallBridge.dispatchIncomingCallAction("decline", peer)
                finish()
            },
        )
    }

    private fun currentPeerAddress(): String {
        return intent?.getStringExtra(EXTRA_PEER_ADDRESS)
            ?: ZenCallBridge.pendingPeerAddress
    }

    private fun startRinging() {
        if (ringing) {
            return
        }
        ringing = true
        try {
            // Zen's own gentle ringtone (res/raw/zen_ringtone.ogg).
            val uri = Uri.parse("android.resource://$packageName/${R.raw.zen_ringtone}")
            val tone = RingtoneManager.getRingtone(this, uri)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                tone?.isLooping = true
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                tone?.audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            }
            tone?.play()
            ringtone = tone
        } catch (_: Exception) {
        }
        try {
            val vibe = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(VIBRATOR_SERVICE) as? Vibrator
            }
            vibrator = vibe
            if (vibe != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibe.vibrate(
                    VibrationEffect.createWaveform(
                        longArrayOf(0, 500, 200, 500, 200, 800),
                        0,
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                vibe?.vibrate(longArrayOf(0, 500, 200, 500, 200, 800), 0)
            }
        } catch (_: Exception) {
        }
    }

    private fun stopRinging() {
        ringing = false
        try {
            ringtone?.stop()
        } catch (_: Exception) {
        }
        ringtone = null
        try {
            vibrator?.cancel()
        } catch (_: Exception) {
        }
        vibrator = null
    }

    private fun acceptAfterUnlock(routeKey: String, peerAddress: String) {
        // Start the WebRTC handshake immediately so it runs while the user
        // types the PIN. Unlocking only reveals the already-connecting UI.
        stopRinging()
        ZenCallBridge.dispatchIncomingCallAction("accept", peerAddress)
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        val locked = keyguard?.isKeyguardLocked == true
        if (!locked || Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1 || keyguard == null) {
            ZenCallBridge.launchMainForAccept(this, routeKey, peerAddress)
            finish()
            return
        }
        keyguard.requestDismissKeyguard(
            this,
            object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() {
                    ZenCallBridge.launchMainForAccept(this@IncomingCallActivity, routeKey, peerAddress)
                    finish()
                }

                override fun onDismissCancelled() {
                    ZenCallBridge.dispatchIncomingCallAction("decline", peerAddress)
                    finish()
                }

                override fun onDismissError() {
                    ZenCallBridge.dispatchIncomingCallAction("decline", peerAddress)
                    finish()
                }
            },
        )
    }

    companion object {
        const val ACTION_INCOMING_CALL = "com.roj.zen.INCOMING_CALL"
        const val EXTRA_DISPLAY_NAME = "display_name"
        const val EXTRA_IS_VIDEO = "is_video"
        const val EXTRA_PEER_ADDRESS = "peer_address"
        const val EXTRA_ACCEPT_ROUTE = "accept_route_key"

        private var instance: WeakReference<IncomingCallActivity>? = null

        val isShowing: Boolean
            get() = instance?.get() != null

        fun finishIfShowing() {
            instance?.get()?.let { activity ->
                activity.stopRinging()
                activity.finish()
            }
        }
    }
}
