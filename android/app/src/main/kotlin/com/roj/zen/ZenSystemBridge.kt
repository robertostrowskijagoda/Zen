package com.roj.zen

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * Small system actions (`zen/system`): open the dialer with a number (the
 * person presses call; no permission needed), open the SMS app with a
 * ready text (no SEND_SMS permission), open a map at a place, tell
 * the Android API level (which foreground-service type the background
 * service may use), open this app's page in the system settings (where
 * phone makers keep their own battery limits), open the "open by default"
 * page (so a Zen QR scanned with the camera opens straight in Zen) and open
 * an https page in the browser. `setDisguise` switches the launcher entry
 * between Zen's own icon and name and a neutral notes one (two
 * activity-aliases, exactly one enabled). `soundsSilenced` tells
 * whether the phone keeps quiet (Zen's in-app sounds follow it).
 *
 * Account backup files (account_backup_places.dart): `exportToDownloads`
 * {paths, name} copies the written parts into the Downloads folder through
 * the media store (Android 10+, no storage permission) and answers
 * {names, paths} (null before Android 10); `pickFolder` opens the system's
 * folder chooser and answers {tree, label} (null when cancelled);
 * `exportToFolder` {tree, paths, name} copies the parts into that folder;
 * `openDownloads` and `openFolder` {tree} show them. The first part is
 * named [name], part n `<first>.n` (after any rename the system did).
 */
object ZenSystemBridge {
    private const val TAG = "ZenSystem"
    private const val CHANNEL = "zen/system"

    /** [engine] is going away: its handler (it holds the Activity) goes with it. */
    fun unregister(engine: FlutterEngine) {
        engine.dartExecutor.binaryMessenger.setMessageHandler(CHANNEL, null)
    }

    fun register(engine: FlutterEngine, activity: FragmentActivity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "dial" -> {
                            val number = call.argument<String>("number") ?: ""
                            activity.startActivity(
                                Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(number))),
                            )
                            result.success(true)
                        }
                        "sms" -> {
                            // The system SMS app with the text ready; the
                            // person presses send (no SEND_SMS permission).
                            val numbers = call.argument<List<String>>("numbers") ?: emptyList()
                            val body = call.argument<String>("body") ?: ""
                            val to = numbers.joinToString(";") { Uri.encode(it, "+") }
                            activity.startActivity(
                                Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$to"))
                                    .putExtra("sms_body", body),
                            )
                            result.success(true)
                        }
                        "openMap" -> {
                            val lat = call.argument<Double>("lat") ?: 0.0
                            val lon = call.argument<Double>("lon") ?: 0.0
                            val label = Uri.encode(call.argument<String>("label") ?: "")
                            val geo = Intent(
                                Intent.ACTION_VIEW,
                                Uri.parse("geo:$lat,$lon?q=$lat,$lon($label)"),
                            )
                            if (geo.resolveActivity(activity.packageManager) != null) {
                                activity.startActivity(geo)
                            } else {
                                activity.startActivity(
                                    Intent(
                                        Intent.ACTION_VIEW,
                                        Uri.parse("https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=17/$lat/$lon"),
                                    ),
                                )
                            }
                            result.success(true)
                        }
                        "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                        "soundsSilenced" -> result.success(soundsSilenced(activity))
                        "openUrl" -> result.success(openInBrowser(activity, call.argument<String>("url")))
                        "openLinkSettings" -> {
                            val page = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS
                            } else {
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                            }
                            activity.startActivity(
                                Intent(page, Uri.parse("package:${activity.packageName}")),
                            )
                            result.success(true)
                        }
                        "openAppSettings" -> {
                            activity.startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:${activity.packageName}"),
                                ),
                            )
                            result.success(true)
                        }
                        "exportToDownloads" -> {
                            val paths = call.argument<List<String>>("paths") ?: emptyList()
                            val name = call.argument<String>("name") ?: ""
                            inBackground(result) { exportToDownloads(activity, paths, name) }
                        }
                        "pickFolder" -> pickFolder(activity, result)
                        "exportToFolder" -> {
                            val tree = call.argument<String>("tree") ?: ""
                            val paths = call.argument<List<String>>("paths") ?: emptyList()
                            val name = call.argument<String>("name") ?: ""
                            inBackground(result) { exportToFolder(activity, tree, paths, name) }
                        }
                        "openDownloads" -> result.success(
                            showFolder(activity, Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)),
                        )
                        "openFolder" -> {
                            val tree = Uri.parse(call.argument<String>("tree") ?: "")
                            result.success(
                                showFolder(
                                    activity,
                                    Intent(Intent.ACTION_VIEW)
                                        .setDataAndType(
                                            treeDocument(tree),
                                            DocumentsContract.Document.MIME_TYPE_DIR,
                                        )
                                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                                ),
                            )
                        }
                        "setDisguise" -> result.success(
                            setDisguise(activity, call.argument<Boolean>("enabled") ?: false),
                        )
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    Log.w(TAG, "${call.method} failed", error)
                    result.success(false)
                }
            }
    }

    private var folderPickSerial = 0

    /** Runs [work] off the main thread and answers its map (null on failure). */
    private fun inBackground(
        result: MethodChannel.Result,
        work: () -> Map<String, Any>?,
    ) {
        Thread {
            val answer = try {
                work()
            } catch (error: Exception) {
                Log.w(TAG, "Exporting a backup failed", error)
                null
            }
            Handler(Looper.getMainLooper()).post { result.success(answer) }
        }.start()
    }

    private fun showFolder(activity: FragmentActivity, intent: Intent): Boolean =
        try {
            activity.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }

    /** The system's folder chooser: {tree, label}, or null when cancelled. */
    private fun pickFolder(activity: FragmentActivity, result: MethodChannel.Result) {
        var launcher: ActivityResultLauncher<Uri?>? = null
        val registered = activity.activityResultRegistry.register(
            "zen_backup_folder_${folderPickSerial++}",
            object : ActivityResultContracts.OpenDocumentTree() {
                override fun createIntent(context: Context, input: Uri?): Intent =
                    super.createIntent(context, input).addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                    )
            },
        ) { uri ->
            launcher?.unregister()
            result.success(
                if (uri == null) {
                    null
                } else {
                    mapOf(
                        "tree" to uri.toString(),
                        "label" to (displayName(activity, treeDocument(uri)) ?: ""),
                    )
                },
            )
        }
        launcher = registered
        registered.launch(null)
    }

    private fun treeDocument(tree: Uri): Uri =
        DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))

    private fun displayName(context: Context, uri: Uri): String? =
        try {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { if (it.moveToFirst()) it.getString(0) else null }
        } catch (_: Exception) {
            null
        }

    /** The part [index] (from 0) of a backup whose first part ended up as [first]. */
    private fun partName(first: String, index: Int) =
        if (index == 0) first else "$first.${index + 1}"

    private fun copyInto(context: Context, source: String, target: Uri) {
        context.contentResolver.openOutputStream(target, "w")?.use { out ->
            File(source).inputStream().use { it.copyTo(out) }
        } ?: throw IOException("Cannot write $target")
    }

    /**
     * Copies the backup [paths] into Downloads through the media store; null
     * before Android 10 (Dart keeps the app's own folder then). A part that
     * fails takes the earlier ones with it.
     */
    private fun exportToDownloads(
        context: Context,
        paths: List<String>,
        name: String,
    ): Map<String, Any>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || paths.isEmpty()) {
            return null
        }
        return exportToDownloadsQ(context, paths, name)
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun exportToDownloadsQ(
        context: Context,
        paths: List<String>,
        name: String,
    ): Map<String, Any> {
        val resolver = context.contentResolver
        @Suppress("DEPRECATION")
        val downloads = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS,
        )
        val made = ArrayList<Uri>()
        val names = ArrayList<String>()
        try {
            paths.forEachIndexed { index, source ->
                val values = ContentValues().apply {
                    put(
                        MediaStore.Downloads.DISPLAY_NAME,
                        partName(names.firstOrNull() ?: name, index),
                    )
                    put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IOException("Cannot create the file in Downloads")
                made.add(uri)
                copyInto(context, source, uri)
                resolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) },
                    null,
                    null,
                )
                names.add(displayName(context, uri) ?: partName(name, index))
            }
        } catch (error: Exception) {
            made.forEach { runCatching { resolver.delete(it, null, null) } }
            throw error
        }
        return mapOf(
            "names" to names,
            "paths" to names.map { File(downloads, it).path },
        )
    }

    /** Copies the backup [paths] into the folder behind [tree]. */
    private fun exportToFolder(
        context: Context,
        tree: String,
        paths: List<String>,
        name: String,
    ): Map<String, Any> {
        val parent = treeDocument(Uri.parse(tree))
        val made = ArrayList<Uri>()
        val names = ArrayList<String>()
        try {
            paths.forEachIndexed { index, source ->
                val uri = DocumentsContract.createDocument(
                    context.contentResolver,
                    parent,
                    "application/octet-stream",
                    partName(names.firstOrNull() ?: name, index),
                ) ?: throw IOException("Cannot create the file in the folder")
                made.add(uri)
                copyInto(context, source, uri)
                names.add(displayName(context, uri) ?: partName(name, index))
            }
        } catch (error: Exception) {
            made.forEach {
                runCatching { DocumentsContract.deleteDocument(context.contentResolver, it) }
            }
            throw error
        }
        return mapOf("names" to names)
    }

    private fun alias(activity: FragmentActivity, name: String) =
        ComponentName(activity.packageName, "${activity.packageName}.$name")

    /**
     * Enables the launcher alias for the wanted look and disables the other,
     * so exactly one launcher entry exists. The wanted one is enabled first:
     * there is never a moment with none. DONT_KILL_APP keeps the app running
     * (some launchers still take a moment to refresh their icon).
     */
    private fun setDisguise(activity: FragmentActivity, enabled: Boolean): Boolean {
        val pm = activity.packageManager
        val on = alias(activity, if (enabled) "LauncherDisguise" else "LauncherDefault")
        val off = alias(activity, if (enabled) "LauncherDefault" else "LauncherDisguise")
        pm.setComponentEnabledSetting(
            on,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        pm.setComponentEnabledSetting(
            off,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
        return true
    }

    /**
     * Only https, and in a browser: Zen itself answers links to its own
     * GitHub page (invitations), so a plain VIEW could come straight back.
     */
    /**
     * Whether the phone is set to keep quiet: silent or vibrate mode, or
     * "Do not disturb" in any form. Zen's in-app sounds stay silent then.
     */
    private fun soundsSilenced(context: Context): Boolean {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        if (audio != null && audio.ringerMode != AudioManager.RINGER_MODE_NORMAL) {
            return true
        }
        val notifications =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            notifications != null &&
            notifications.currentInterruptionFilter > NotificationManager.INTERRUPTION_FILTER_ALL
    }

    private fun openInBrowser(activity: FragmentActivity, url: String?): Boolean {
        val uri = Uri.parse(url ?: return false)
        if (uri.scheme != "https" || uri.host.isNullOrEmpty()) {
            return false
        }
        val view = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
        return try {
            activity.startActivity(
                Intent(view).apply {
                    selector = Intent.makeMainSelectorActivity(
                        Intent.ACTION_MAIN,
                        Intent.CATEGORY_APP_BROWSER,
                    )
                },
            )
            true
        } catch (_: android.content.ActivityNotFoundException) {
            activity.startActivity(view)
            true
        }
    }
}
