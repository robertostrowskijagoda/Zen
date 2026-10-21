package com.roj.zen

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.location.LocationManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/**
 * Network updates on Android:
 *  - `zen/app_update`: the APK this app was installed from (to pass on),
 *    and handing a downloaded update to the system installer (the person
 *    confirms in the system dialog; nothing installs silently);
 *  - `zen/share_app`: a local-only Wi-Fi hotspot, so a friend nearby can
 *    download the app from this phone with no internet at all, and the
 *    installer handed to the system share sheet (Quick Share, Bluetooth).
 */
object ZenUpdateBridge {
    private const val TAG = "ZenUpdate"
    private const val ACTION_STATUS = "com.roj.zen.INSTALL_STATUS"
    private const val PERMISSION_REQUEST = 3101

    /** Cache subfolder served by [ZenFileProvider] (res/xml/zen_share_paths.xml). */
    private const val SHARE_DIR = "shared_apk"

    /** `${applicationId}.zenshare` in the manifest. */
    private const val SHARE_AUTHORITY_SUFFIX = ".zenshare"
    private const val APK_MIME = "application/vnd.android.package-archive"

    private var statusReceiver: BroadcastReceiver? = null
    private var hotspot: WifiManager.LocalOnlyHotspotReservation? = null

    fun register(engine: FlutterEngine, activity: FragmentActivity) {
        val messenger = engine.dartExecutor.binaryMessenger
        registerStatusReceiver(activity)
        MethodChannel(messenger, "zen/app_update").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "apkPath" -> {
                        val info = activity.applicationInfo
                        val splits = info.splitSourceDirs
                        // An app installed from split APKs cannot be passed
                        // on as one file.
                        result.success(if (splits == null || splits.isEmpty()) info.sourceDir else null)
                    }
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            activity.packageManager.canRequestPackageInstalls(),
                    )
                    "openInstallSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            activity.startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:${activity.packageName}"),
                                ),
                            )
                        }
                        result.success(null)
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null || !File(path).exists()) {
                            result.error("install", "File missing", null)
                        } else {
                            install(activity, File(path))
                            result.success(activity.getString(R.string.update_installer_opened))
                        }
                    }
                    "signingCertificates" -> {
                        // This app's own signing certificates and,
                        // when the system verified its signature, those of
                        // the APK at `path` (SHA-256, lower-case hex).
                        val path = call.argument<String>("path")
                        result.success(
                            mapOf(
                                "own" to ownCertificates(activity),
                                "apk" to path?.let { archiveCertificates(activity, it) },
                            ),
                        )
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                Log.w(TAG, "app_update ${call.method} failed", error)
                result.error("app_update", error.message, null)
            }
        }
        MethodChannel(messenger, "zen/share_app").setMethodCallHandler { call, result ->
            when (call.method) {
                "startHotspot" -> startHotspot(activity, result)
                "stopHotspot" -> {
                    stopHotspot()
                    result.success(null)
                }
                "shareApk" -> shareApk(
                    activity,
                    call.argument<String>("path"),
                    call.argument<String>("name"),
                    result,
                )
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Hands an installer to the system share sheet (Quick Share, Bluetooth,
     * ...): phone to phone, no internet needed. [path] is the file to send
     * (a newer signed release, say); without it, the APK this app was
     * installed from. The file is copied into the cache first: the
     * FileProvider serves nothing else, and the copy gets a readable name.
     *
     * Answers `{ok, baseOnly, name}` once the share sheet is open, or
     * `{error}` (`no_file`, `failed:...`). `baseOnly`: the app was installed
     * from split APKs and only the base one went out, which may not install
     * on its own.
     */
    private fun shareApk(
        activity: FragmentActivity,
        path: String?,
        name: String?,
        result: MethodChannel.Result,
    ) {
        val info = activity.applicationInfo
        val requested = path?.takeIf { it.isNotBlank() }
        val source = File(requested ?: info.sourceDir)
        val splits = info.splitSourceDirs
        val baseOnly = requested == null && splits != null && splits.isNotEmpty()
        val fileName = safeApkName(
            name?.takeIf { it.isNotBlank() } ?: "Zen-${versionName(activity)}.apk",
        )
        val dir = File(activity.cacheDir, SHARE_DIR)
        val main = Handler(Looper.getMainLooper())
        // Tens of megabytes: never on the main thread.
        Thread {
            var shared: File? = null
            var failure = "failed"
            try {
                if (!source.isFile || !source.canRead()) {
                    failure = "no_file"
                } else {
                    if (!dir.isDirectory && !dir.mkdirs()) {
                        throw IOException("Cannot create $dir")
                    }
                    val sourcePath = source.canonicalPath
                    // Only the file being sent stays; earlier copies go.
                    dir.listFiles()?.forEach { old ->
                        if (old.canonicalPath != sourcePath) {
                            old.delete()
                        }
                    }
                    val target = File(dir, fileName)
                    if (target.canonicalPath != sourcePath) {
                        source.inputStream().use { input ->
                            target.outputStream().use { output -> input.copyTo(output) }
                        }
                    }
                    shared = target
                }
            } catch (error: Exception) {
                Log.w(TAG, "Preparing the installer to share failed", error)
                failure = "failed:${error.message}"
            }
            val file = shared
            main.post {
                if (file == null) {
                    result.success(mapOf("error" to failure))
                } else if (activity.isFinishing || activity.isDestroyed) {
                    result.success(mapOf("error" to "failed:activity"))
                } else {
                    try {
                        openShareSheet(activity, file)
                        result.success(
                            mapOf("ok" to true, "baseOnly" to baseOnly, "name" to file.name),
                        )
                    } catch (error: Exception) {
                        Log.w(TAG, "Opening the share sheet failed", error)
                        result.success(mapOf("error" to "failed:${error.message}"))
                    }
                }
            }
        }.start()
    }

    private fun openShareSheet(activity: FragmentActivity, file: File) {
        val uri = FileProvider.getUriForFile(
            activity,
            activity.packageName + SHARE_AUTHORITY_SUFFIX,
            file,
        )
        val send = Intent(Intent.ACTION_SEND).apply {
            type = APK_MIME
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_TITLE, file.name)
            // The chooser passes the read grant on to the app picked.
            clipData = ClipData.newRawUri(file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(Intent.createChooser(send, activity.getString(R.string.share_zen_chooser)))
    }

    /** SHA-256 of each certificate: the fingerprint `apksigner` prints. */
    private fun fingerprints(signatures: Array<Signature>?): List<String> =
        signatures?.map { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString("") { byte -> (byte.toInt() and 0xff).toString(16).padStart(2, '0') }
        } ?: emptyList()

    @Suppress("DEPRECATION")
    private fun signingFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }

    /** The signer's certificates, with the past ones of a rotated key. */
    @Suppress("DEPRECATION")
    private fun certificatesOf(info: PackageInfo?): List<String> {
        if (info == null) {
            return emptyList()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = info.signingInfo ?: return emptyList()
            return if (signing.hasMultipleSigners()) {
                fingerprints(signing.apkContentsSigners)
            } else {
                fingerprints(signing.signingCertificateHistory)
            }
        }
        return fingerprints(info.signatures)
    }

    @Suppress("DEPRECATION")
    private fun ownCertificates(context: Context): List<String> =
        try {
            certificatesOf(context.packageManager.getPackageInfo(context.packageName, signingFlags()))
        } catch (error: Exception) {
            Log.w(TAG, "Reading the own signature failed", error)
            emptyList()
        }

    /** Null when the system could not read or verify the file's signature. */
    @Suppress("DEPRECATION")
    private fun archiveCertificates(context: Context, path: String): List<String>? =
        try {
            if (!File(path).isFile) {
                null
            } else {
                certificatesOf(context.packageManager.getPackageArchiveInfo(path, signingFlags()))
                    .ifEmpty { null }
            }
        } catch (error: Exception) {
            Log.w(TAG, "Reading an APK signature failed", error)
            null
        }

    @Suppress("DEPRECATION")
    private fun versionName(context: Context): String =
        try {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "app"
        } catch (_: Exception) {
            "app"
        }

    /** Letters, digits, dots, dashes and underscores; always `.apk`. */
    private fun safeApkName(name: String): String {
        val cleaned = name.replace(Regex("[^A-Za-z0-9._-]"), "_").trim('.', '_')
        val base = cleaned.ifEmpty { "Zen" }
        return if (base.lowercase().endsWith(".apk")) base else "$base.apk"
    }

    private fun registerStatusReceiver(activity: FragmentActivity) {
        statusReceiver?.let {
            try {
                activity.applicationContext.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        @Suppress("DEPRECATION")
                        val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        if (confirm != null) {
                            confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(confirm)
                        }
                    }
                    PackageInstaller.STATUS_SUCCESS -> Log.i(TAG, "Update installed")
                    else -> Log.w(
                        TAG,
                        "Install status: ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}",
                    )
                }
            }
        }
        ContextCompat.registerReceiver(
            activity.applicationContext,
            receiver,
            IntentFilter(ACTION_STATUS),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        statusReceiver = receiver
    }

    private fun install(activity: FragmentActivity, apk: File) {
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(activity.packageName)
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("zen.apk", 0, apk.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val intent = Intent(ACTION_STATUS).setPackage(activity.packageName)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // The installer fills in the status extras.
                flags = flags or PendingIntent.FLAG_MUTABLE
            }
            val pending = PendingIntent.getBroadcast(activity, sessionId, intent, flags)
            session.commit(pending.intentSender)
        }
    }

    private fun hotspotPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun startHotspot(activity: FragmentActivity, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(mapOf("error" to "unsupported"))
            return
        }
        val missing = hotspotPermissions().filter {
            ContextCompat.checkSelfPermission(activity, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            ActivityCompat.requestPermissions(activity, missing.toTypedArray(), PERMISSION_REQUEST)
            result.success(mapOf("error" to "permission"))
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            val location = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val on = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                location.isLocationEnabled
            } else {
                location.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    location.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            }
            if (!on) {
                result.success(mapOf("error" to "location_off"))
                return
            }
        }
        val current = hotspot
        if (current != null) {
            result.success(describe(current))
            return
        }
        val wifi = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        var answered = false
        try {
            wifi.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        hotspot = reservation
                        if (!answered) {
                            answered = true
                            result.success(describe(reservation))
                        }
                    }

                    override fun onStopped() {
                        hotspot = null
                    }

                    override fun onFailed(reason: Int) {
                        if (!answered) {
                            answered = true
                            result.success(mapOf("error" to "failed:$reason"))
                        }
                    }
                },
                Handler(Looper.getMainLooper()),
            )
        } catch (error: Exception) {
            Log.w(TAG, "Local-only hotspot failed", error)
            if (!answered) {
                answered = true
                result.success(mapOf("error" to "failed:${error.message}"))
            }
        }
    }

    private fun describe(reservation: WifiManager.LocalOnlyHotspotReservation): Map<String, Any?> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val config = reservation.softApConfiguration
            @Suppress("DEPRECATION")
            val ssid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                config.wifiSsid?.toString()?.trim('"')
            } else {
                config.ssid
            }
            return mapOf("ssid" to ssid, "password" to config.passphrase)
        }
        @Suppress("DEPRECATION")
        val config = reservation.wifiConfiguration
        @Suppress("DEPRECATION")
        return mapOf("ssid" to config?.SSID?.trim('"'), "password" to config?.preSharedKey?.trim('"'))
    }

    private fun stopHotspot() {
        hotspot?.close()
        hotspot = null
    }
}
