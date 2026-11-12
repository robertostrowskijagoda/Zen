package com.roj.zen

/**
 * Android's window for an inexact alarm (`set`, `setAndAllowWhileIdle`) on
 * Android 12 and later, as AlarmManagerService gives it: an alarm asked for
 * in `d` may come up to 3/4 of `d` late (no window under 10 s), and comes
 * at the window's end unless something else wakes the phone first; never
 * before the time asked for. (zen_wake.dart plans the beat's wakes by the
 * same numbers, kInexactWindowStretch.)
 */
internal object InexactAlarmWindow {
    /** The window's end, as a part of the delay asked for: 1 + 3/4. */
    const val STRETCH = 1.75

    /** Shorter delays get no window. */
    const val NO_WINDOW_UNDER_MS = 10_000L

    /**
     * The delay to ask an inexact alarm for so that its window ends
     * [delayMs] from now, where an exact one is not allowed: it comes then
     * at the latest, or earlier with another wake of the phone. [delayMs]
     * itself when no window can end there (it would be under 10 s): then it
     * comes on time, or at most 3/4 of [delayMs] late.
     */
    fun delayEndingIn(delayMs: Long): Long {
        if (delayMs <= 0) {
            return 0
        }
        val sooner = Math.ceil(delayMs / STRETCH).toLong()
        return if (sooner < NO_WINDOW_UNDER_MS) delayMs else sooner
    }
}
