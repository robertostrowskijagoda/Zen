package com.roj.zen

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log

/**
 * A Zen file opened from another app (a backup, a key backup, an update
 * tapped in Files, a mail or a chat). Started straight, MainActivity would
 * run a second copy of the app inside that app's task, with an engine of
 * its own beside the running one; this hands the file to the one in Zen's
 * own task instead, read access included. app_links passes the address on
 * to Dart, which copies the file (ZenSystemBridge "copyOpenedFile") and
 * opens the matching screen once Zen is unlocked.
 */
class ZenOpenFileActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val file = intent?.data
        if (file != null && file.scheme == "content") {
            val open = Intent(Intent.ACTION_VIEW, file).apply {
                setClass(this@ZenOpenFileActivity, MainActivity::class.java)
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
            try {
                startActivity(open)
            } catch (error: Exception) {
                Log.w(TAG, "Handing the opened file to the app failed", error)
            }
        }
        // Theme.NoDisplay: finished before it would be shown.
        finish()
    }

    companion object {
        private const val TAG = "ZenOpenFile"
    }
}
