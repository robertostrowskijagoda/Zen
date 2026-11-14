package com.roj.zen

/**
 * Who wants the app's window to keep the screen on: a call ringing on it
 * (the ringing overlay) and a running call (call_screen_awake.dart). The
 * window has `FLAG_KEEP_SCREEN_ON` while either does. The end of the
 * ringing used to clear the flag outright, also when the call it rang for
 * went on in the same window and wanted the screen on.
 */
class CallScreenKeepOn {
    @Volatile
    var ringing: Boolean = false

    @Volatile
    var call: Boolean = false

    /** Whether the window keeps the screen on. */
    val wanted: Boolean
        get() = ringing || call
}
