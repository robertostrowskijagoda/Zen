package com.roj.zen

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Log
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource

/**
 * Security channels on Android:
 *  - `zen/secure_window`: FLAG_SECURE on the window (no screenshots, no
 *    recording, blank in the recent apps);
 *  - `zen/keyvault`: the app's master key wrapped by an RSA key pair in the
 *    Android Keystore (StrongBox when there is one). Wrapping uses only the
 *    public key; unwrapping needs the private key, which the Keystore
 *    releases only after a strong biometric check in the system prompt and
 *    which is destroyed when a new fingerprint or face is enrolled;
 *  - `zen/integrity`: signs of a rooted or modified phone (a warning only),
 *    and of someone inside this very process — a debugger, Frida, Xposed or
 *    LSPosed hooks (device_integrity.dart then also refuses payments and the
 *    pyramid's power key while they are there).
 */
object ZenSecurityBridge {
    private const val TAG = "ZenSecurity"
    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "zen_master_wrap_v1"
    private const val TRANSFORMATION = "RSA/ECB/OAEPWithSHA-256AndMGF1Padding"
    private const val PREFS = "zen_secure_window"
    private const val PREF_SECURE = "secure"
    private const val SECURE_WINDOW_CHANNEL = "zen/secure_window"
    private const val KEYVAULT_CHANNEL = "zen/keyvault"
    private const val INTEGRITY_CHANNEL = "zen/integrity"

    private val main = Handler(Looper.getMainLooper())

    /**
     * The integrity check reads files under /proc and asks the package
     * manager about a dozen apps: never on the main thread.
     */
    private val checks = Executors.newSingleThreadExecutor { Thread(it, "zen-integrity") }

    private val oaep = OAEPParameterSpec(
        "SHA-256",
        "MGF1",
        MGF1ParameterSpec.SHA1,
        PSource.PSpecified.DEFAULT,
    )

    fun register(engine: FlutterEngine, activity: FragmentActivity) {
        val messenger = engine.dartExecutor.binaryMessenger
        // From the first frame, as the app last left it: Dart says again once
        // its settings are loaded, but a recent-apps preview or a screenshot
        // could be taken before that.
        applySecure(activity, wasSecure(activity))
        MethodChannel(messenger, SECURE_WINDOW_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> {
                    // While "Blokuj zrzuty i nagrywanie ekranu" is on, Dart keeps the
                    // whole window secure, not only the protected screens:
                    // the recent-apps preview is taken whenever the app is left,
                    // from whatever screen is open then (the chat list too).
                    val secure = call.argument<Boolean>("secure") ?: false
                    activity.runOnUiThread { applySecure(activity, secure) }
                    rememberSecure(activity, secure)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, KEYVAULT_CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "available" -> result.success(available(activity))
                    "describe" -> result.success(describe())
                    "seal" -> {
                        val data = call.argument<ByteArray>("data")
                        if (data == null || !available(activity)) {
                            result.success(null)
                        } else {
                            result.success(seal(data))
                        }
                    }
                    "open" -> {
                        val data = call.argument<ByteArray>("data")
                        val reason = call.argument<String>("reason") ?: activity.getString(R.string.biometric_unlock_reason)
                        if (data == null) {
                            result.success(null)
                        } else {
                            open(activity, data, reason, result)
                        }
                    }
                    "wipe" -> {
                        keyStore().deleteEntry(ALIAS)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                Log.w(TAG, "Key vault ${call.method} failed", error)
                result.error("vault", error.message, null)
            }
        }
        val app = activity.applicationContext
        MethodChannel(messenger, INTEGRITY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "check" -> {
                    // The main thread's own stack (hooks show in it, not in
                    // the worker's), taken here; the rest on the worker.
                    val mainStack = Throwable().stackTrace
                    try {
                        checks.execute {
                            val found = try {
                                integrity(app, mainStack)
                            } catch (error: Exception) {
                                Log.w(TAG, "The integrity check failed", error)
                                null
                            }
                            main.post {
                                if (found != null) {
                                    result.success(found)
                                } else {
                                    result.error("integrity", "check failed", null)
                                }
                            }
                        }
                    } catch (error: RejectedExecutionException) {
                        result.error("integrity", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** [engine] is going away: its handlers (they hold the Activity) go with it. */
    fun unregister(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        for (name in listOf(SECURE_WINDOW_CHANNEL, KEYVAULT_CHANNEL, INTEGRITY_CHANNEL)) {
            messenger.setMessageHandler(name, null)
        }
    }

    /** FLAG_SECURE (no screenshots, recording or casting) and no recent-apps preview. */
    private fun applySecure(activity: FragmentActivity, secure: Boolean) {
        if (secure) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.setRecentsScreenshotEnabled(!secure)
        }
    }

    private fun wasSecure(activity: FragmentActivity): Boolean =
        try {
            activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(PREF_SECURE, true)
        } catch (_: Exception) {
            true
        }

    private fun rememberSecure(activity: FragmentActivity, secure: Boolean) {
        try {
            activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(PREF_SECURE, secure)
                .apply()
        } catch (error: Exception) {
            Log.w(TAG, "Remembering the screen protection failed", error)
        }
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    private fun available(activity: FragmentActivity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return false
        }
        return BiometricManager.from(activity)
            .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS
    }

    private fun describe(): String {
        return try {
            val key = keyStore().getKey(ALIAS, null) as? PrivateKey
                ?: return "Android Keystore"
            val factory = KeyFactory.getInstance(key.algorithm, KEYSTORE)
            val info = factory.getKeySpec(key, KeyInfo::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                when (info.securityLevel) {
                    KeyProperties.SECURITY_LEVEL_STRONGBOX -> "Android Keystore (StrongBox)"
                    KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "Android Keystore (TEE)"
                    else -> "Android Keystore (programowy)"
                }
            } else {
                @Suppress("DEPRECATION")
                if (info.isInsideSecureHardware) "Android Keystore (TEE)" else "Android Keystore (programowy)"
            }
        } catch (error: Exception) {
            "Android Keystore"
        }
    }

    private fun ensureKeyPair() {
        if (keyStore().containsAlias(ALIAS)) {
            return
        }
        fun spec(strongBox: Boolean): KeyGenParameterSpec {
            val builder = KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setKeySize(2048)
                .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA1)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
                .setUserAuthenticationRequired(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                builder.setInvalidatedByBiometricEnrollment(true)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setUserAuthenticationParameters(
                    0,
                    KeyProperties.AUTH_BIOMETRIC_STRONG,
                )
            }
            if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                builder.setIsStrongBoxBacked(true)
            }
            return builder.build()
        }
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, KEYSTORE)
        try {
            generator.initialize(spec(strongBox = true))
            generator.generateKeyPair()
        } catch (error: Exception) {
            // No StrongBox (most phones): the TEE.
            generator.initialize(spec(strongBox = false))
            generator.generateKeyPair()
        }
    }

    private fun seal(data: ByteArray): ByteArray {
        ensureKeyPair()
        val stored = keyStore().getCertificate(ALIAS).publicKey
        // A plain copy of the public key: encrypting needs no authentication.
        val publicKey = KeyFactory.getInstance(stored.algorithm)
            .generatePublic(X509EncodedKeySpec(stored.encoded))
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, publicKey, oaep)
        return cipher.doFinal(data)
    }

    private fun open(
        activity: FragmentActivity,
        data: ByteArray,
        reason: String,
        result: MethodChannel.Result,
    ) {
        val key = keyStore().getKey(ALIAS, null) as? PrivateKey
        if (key == null) {
            result.success(null)
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        try {
            cipher.init(Cipher.DECRYPT_MODE, key, oaep)
        } catch (error: KeyPermanentlyInvalidatedException) {
            // A new fingerprint or face was enrolled: the key is gone for
            // good; the password unlocks and seals again.
            keyStore().deleteEntry(ALIAS)
            result.success(null)
            return
        }
        var answered = false
        fun answer(value: ByteArray?) {
            if (!answered) {
                answered = true
                result.success(value)
            }
        }
        activity.runOnUiThread {
            val prompt = BiometricPrompt(
                activity,
                ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        authResult: BiometricPrompt.AuthenticationResult,
                    ) {
                        try {
                            answer(authResult.cryptoObject?.cipher?.doFinal(data))
                        } catch (error: Exception) {
                            Log.w(TAG, "Unwrapping the key failed", error)
                            answer(null)
                        }
                    }

                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        answer(null)
                    }
                },
            )
            val info = BiometricPrompt.PromptInfo.Builder()
                .setTitle("Zen")
                .setSubtitle(reason)
                .setNegativeButtonText(activity.getString(R.string.biometric_use_password))
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                .build()
            prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
        }
    }

    /** Worker thread ([checks]): file reads and package manager calls. */
    private fun integrity(context: Context, mainStack: Array<StackTraceElement>): Map<String, Any> {
        val reasons = mutableListOf<String>()
        val suPaths = listOf(
            "/system/bin/su", "/system/xbin/su", "/sbin/su", "/system/su",
            "/system/bin/.ext/.su", "/system/usr/we-need-root/su-backup",
            "/data/local/su", "/data/local/bin/su", "/data/local/xbin/su",
            "/su/bin/su", "/system/app/Superuser.apk", "/sbin/.magisk",
            "/data/adb/magisk", "/data/adb/modules",
        )
        if (suPaths.any { File(it).exists() }) {
            reasons.add("su")
        }
        if (Build.TAGS?.contains("test-keys") == true) {
            reasons.add("test-keys")
        }
        val rootApps = listOf(
            "com.topjohnwu.magisk", "eu.chainfire.supersu", "com.noshufou.android.su",
            "com.koushikdutta.superuser", "com.thirdparty.superuser",
            "com.kingroot.kinguser", "de.robv.android.xposed.installer",
            "org.lsposed.manager", "io.github.lsposed.manager",
        )
        for (pkg in rootApps) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    context.packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
                } else {
                    @Suppress("DEPRECATION")
                    context.packageManager.getPackageInfo(pkg, 0)
                }
                reasons.add("app:$pkg")
            } catch (_: PackageManager.NameNotFoundException) {
            }
        }
        val path = System.getenv("PATH") ?: ""
        if (path.split(":").any { File(it, "su").exists() }) {
            if (!reasons.contains("su")) reasons.add("su")
        }
        // Frida's default server port and library names.
        if (File("/data/local/tmp/frida-server").exists() ||
            File("/data/local/tmp/re.frida.server").exists()
        ) {
            reasons.add("frida")
        }
        val debuggable =
            (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val rooted = reasons.isNotEmpty()
        // Inside this process right now (each check on its own: one failing
        // read says nothing about the others).
        val tamper = mutableListOf<String>()
        if (debuggerAttached()) tamper.add("debugger")
        val maps = readText("/proc/self/maps")
        if (maps != null) {
            val lower = maps.lowercase()
            if (FRIDA_MARKS.any { lower.contains(it) }) tamper.add("frida-loaded")
            if (HOOK_MARKS.any { lower.contains(it) }) tamper.add("hooks")
        }
        if (!tamper.contains("hooks") && xposedLoaded(mainStack)) tamper.add("hooks")
        if (fridaPortOpen()) tamper.add("frida-port")
        val emulator = looksLikeEmulator()
        if (emulator) reasons.add("emulator")
        reasons.addAll(tamper)
        return mapOf(
            "rooted" to rooted,
            "reasons" to reasons,
            "debuggable" to debuggable,
            "tampered" to tamper.isNotEmpty(),
            "emulator" to emulator,
        )
    }

    /** Library names Frida leaves in a process it is inside. */
    private val FRIDA_MARKS = listOf("frida", "gum-js-loop", "linjector")

    /** Hooking frameworks' libraries in the process. */
    private val HOOK_MARKS = listOf(
        "xposedbridge", "libxposed", "liblspd", "lspd", "edxp", "libriru", "libsandhook",
        "substrate", "libwhale", "libpine",
    )

    private fun readText(path: String): String? =
        try {
            File(path).readText()
        } catch (_: Exception) {
            null
        }

    /** A debugger: the VM's own, or any tracer of the process (TracerPid). */
    private fun debuggerAttached(): Boolean {
        if (android.os.Debug.isDebuggerConnected() || android.os.Debug.waitingForDebugger()) {
            return true
        }
        val status = readText("/proc/self/status") ?: return false
        val line = status.lineSequence().firstOrNull { it.startsWith("TracerPid:") } ?: return false
        return line.substringAfter(':').trim().toIntOrNull()?.let { it != 0 } ?: false
    }

    /**
     * Xposed's bridge class reachable from the app's class loader, or its
     * frames in the main thread's stack ([mainStack]).
     */
    private fun xposedLoaded(mainStack: Array<StackTraceElement>): Boolean {
        val bridge = try {
            Class.forName("de.robv.android.xposed.XposedBridge", false, ClassLoader.getSystemClassLoader())
            true
        } catch (_: Throwable) {
            false
        }
        return bridge ||
            mainStack.any { it.className.contains("xposed", ignoreCase = true) }
    }

    /** Frida's server listening on its default port (27042) on this device. */
    private fun fridaPortOpen(): Boolean {
        for (table in listOf("/proc/net/tcp", "/proc/net/tcp6")) {
            val text = readText(table) ?: continue
            for (line in text.lineSequence().drop(1)) {
                val fields = line.trim().split(Regex("\\s+"))
                if (fields.size < 4) continue
                val port = fields[1].substringAfterLast(':')
                // State 0A: listening.
                if (port.equals("69A2", ignoreCase = true) && fields[3] == "0A") {
                    return true
                }
            }
        }
        return false
    }

    /** Hints of an emulator (a hint only, never a block). */
    private fun looksLikeEmulator(): Boolean {
        val fingerprint = Build.FINGERPRINT ?: ""
        val hardware = Build.HARDWARE ?: ""
        val product = Build.PRODUCT ?: ""
        return fingerprint.startsWith("generic") ||
            fingerprint.contains("emulator") ||
            hardware.contains("goldfish") ||
            hardware.contains("ranchu") ||
            product.contains("sdk_gphone") ||
            product.contains("emulator") ||
            File("/dev/qemu_pipe").exists()
    }
}
