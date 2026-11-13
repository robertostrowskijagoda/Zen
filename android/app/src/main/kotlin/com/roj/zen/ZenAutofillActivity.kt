package com.roj.zen

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.service.autofill.Dataset
import android.util.Log
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import androidx.annotation.RequiresApi

/**
 * The authentication of Zen's autofill suggestion ([ZenAutofillService]):
 * started by the autofill framework, for a result, inside the task of the
 * app whose form is being filled.
 *
 * It shows nothing (a translucent window) and holds no password. It hands
 * the request to [ZenAutofillBridge] and brings up MainActivity in Zen's
 * own task, where the Flutter engine with the unlocked vault runs; the
 * picker there answers through the bridge, which calls [complete]. Started
 * straight, MainActivity would run a second copy of the app inside the
 * other app's task (an engine of its own, locked, beside the running one),
 * as ZenOpenFileActivity explains for opened files; and MainActivity's own
 * launch mode would not change that. So this small activity is what the
 * framework starts and what returns its result.
 *
 * Every way out other than an entry the person picked ends with
 * RESULT_CANCELED and nothing filled: Zen locked, the picker closed, the
 * time ran out, the person came back to the app without picking, the
 * activity was recreated, any error.
 */
@RequiresApi(Build.VERSION_CODES.O)
class ZenAutofillActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Until an entry is picked, the answer is "nothing".
        setResult(Activity.RESULT_CANCELED)
        if (savedInstanceState != null || Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            // Made again after the process was gone: the request went with it.
            finish()
            return
        }
        val request = requestOf(intent)
        if (request == null) {
            finish()
            return
        }
        ZenAutofillBridge.open(this, request)
        try {
            startActivity(
                Intent(this, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP,
                ),
            )
        } catch (error: Exception) {
            Log.w(TAG, "Bringing up Zen failed: ${error.javaClass.simpleName}")
            ZenAutofillBridge.cancel(this)
        }
    }

    override fun onRestart() {
        super.onRestart()
        // Back in front without an answer: the person returned to the app
        // (recent apps, back) instead of picking. Nothing is filled.
        ZenAutofillBridge.cancel(this)
    }

    override fun onDestroy() {
        ZenAutofillBridge.gone(this)
        super.onDestroy()
    }

    /**
     * Answers the framework: [dataset] fills the form, null fills nothing.
     * Called once, by the bridge; the dataset is not kept here.
     */
    fun complete(dataset: Dataset?) {
        if (isFinishing) {
            return
        }
        if (dataset != null) {
            setResult(
                Activity.RESULT_OK,
                Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset),
            )
        } else {
            setResult(Activity.RESULT_CANCELED)
        }
        finish()
    }

    /**
     * The request [ZenAutofillService] put in the intent; null when
     * incomplete. The login's id, the password's, or both: a login in two
     * steps asks for one on each page.
     */
    private fun requestOf(intent: Intent?): ZenAutofillBridge.Request? {
        intent ?: return null
        val pkg = intent.getStringExtra(EXTRA_PACKAGE)?.takeIf { it.isNotBlank() } ?: return null
        val usernameId = autofillIdExtra(intent, EXTRA_USERNAME_ID)
        val passwordId = autofillIdExtra(intent, EXTRA_PASSWORD_ID)
        if (usernameId == null && passwordId == null) {
            return null
        }
        return ZenAutofillBridge.Request(
            packageName = pkg,
            appLabel = appLabel(pkg),
            // A page in a browser is matched by its address, not by the
            // browser's certificate.
            signing = if (intent.hasExtra(EXTRA_WEB_DOMAIN)) null else appSigningOf(pkg),
            webDomain = intent.getStringExtra(EXTRA_WEB_DOMAIN),
            webScheme = intent.getStringExtra(EXTRA_WEB_SCHEME),
            usernameId = usernameId,
            passwordId = passwordId,
        )
    }

    private fun autofillIdExtra(intent: Intent, name: String): AutofillId? =
        // The typed getter from Android 14 (on 13 it can throw by mistake).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            intent.getParcelableExtra(name, AutofillId::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(name) as? AutofillId
        }

    /**
     * The app's name as it calls itself, shown next to its package (never
     * alone: any app can call itself anything). Null when Android does not
     * show Zen that app.
     */
    @Suppress("DEPRECATION")
    private fun appLabel(pkg: String): String? = try {
        val info = packageManager.getApplicationInfo(pkg, 0)
        packageManager.getApplicationLabel(info).toString().trim().takeIf { it.isNotEmpty() }
    } catch (_: Exception) {
        null
    }

    /**
     * The certificates [pkg] is signed with ([appSigning]); null when
     * Android does not show Zen that app or tells nothing.
     */
    private fun appSigningOf(pkg: String): AppSigning? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return null
        }
        return try {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    pkg,
                    PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong()),
                )
            } else {
                packageManager.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
            }
            val signing = info.signingInfo ?: return null
            val multiple = signing.hasMultipleSigners()
            val certificates = if (multiple) {
                signing.apkContentsSigners
            } else {
                signing.signingCertificateHistory
            }
            appSigning(certificates.orEmpty().map { it.toByteArray() }, multiple)
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        private const val TAG = "ZenAutofill"
        const val EXTRA_PACKAGE = "com.roj.zen.autofill.PACKAGE"
        const val EXTRA_WEB_DOMAIN = "com.roj.zen.autofill.WEB_DOMAIN"
        const val EXTRA_WEB_SCHEME = "com.roj.zen.autofill.WEB_SCHEME"
        const val EXTRA_USERNAME_ID = "com.roj.zen.autofill.USERNAME_ID"
        const val EXTRA_PASSWORD_ID = "com.roj.zen.autofill.PASSWORD_ID"
    }
}
