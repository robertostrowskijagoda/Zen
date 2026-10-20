package com.roj.zen

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom

/**
 * Wi-Fi Direct for direct links with friends nearby without a Wi-Fi network
 * (§5.1 item 6; `zen/wifi_direct` + events on `zen/wifi_direct/events`).
 * It only makes a network: once phones share a Wi-Fi Direct group, the
 * bridge's LAN discovery runs over it (lan_discovery.go) and links friends
 * as on any Wi-Fi. Dart decides everything (wifi_direct_local_link.dart);
 * this file only drives the radio:
 *  - a DNS-SD service record whose TXT carries the bridge's advert (a
 *    Bloom filter only friends can test, renewed every few minutes; never
 *    a name or an address) and, while this phone runs a group, the group's
 *    name and passphrase, so a friend joins without a system prompt
 *    (Android 10+ `WifiP2pConfig.Builder`);
 *  - service discovery in short windows Dart asks for (battery);
 *  - creating, joining and removing an autonomous group.
 * Anyone nearby could read a group's passphrase from the record and join
 * it: that gives them nothing, the bridge links only devices that prove a
 * pair secret.
 *
 * Needs Android 10 (joining a group by name and passphrase), the Wi-Fi
 * Direct feature, and NEARBY_WIFI_DEVICES (Android 13+) or the location
 * permission (before). Both the app's engine and the background service's
 * may use it; the radio runs while any of them wants it.
 */
object ZenWifiDirectBridge {
    private const val TAG = "ZenWifiDirect"
    private const val PERMISSION_REQUEST = 3401
    private const val SERVICE_TYPE = "_zl._tcp"
    private const val MAX_ADVERT_CHARS = 200

    private class Client(val engine: FlutterEngine, val activity: FragmentActivity?) {
        var sink: EventChannel.EventSink? = null
        var active = false
    }

    private val clients = ArrayList<Client>()
    private val main = Handler(Looper.getMainLooper())
    private val random = SecureRandom()
    private var appContext: Context? = null
    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null
    private var wifiNetworks = HashSet<Network>()
    private var p2pEnabled = false
    private var advert: String? = null
    private var group: WifiP2pGroup? = null
    private var discovering = false
    private val stopDiscovery = Runnable { endDiscovery() }

    fun register(engine: FlutterEngine, activity: FragmentActivity) {
        attach(engine, activity.applicationContext, activity)
    }

    fun registerBackground(engine: FlutterEngine, context: Context) {
        attach(engine, context.applicationContext, null)
    }

    fun unregister(engine: FlutterEngine) {
        if (clients.removeAll { it.engine === engine }) {
            applyActive()
        }
    }

    private fun attach(engine: FlutterEngine, context: Context, activity: FragmentActivity?) {
        appContext = context
        clients.removeAll { it.engine === engine }
        val client = Client(engine, activity)
        clients.add(client)
        val messenger = engine.dartExecutor.binaryMessenger
        EventChannel(messenger, "zen/wifi_direct/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    client.sink = sink
                }

                override fun onCancel(arguments: Any?) {
                    client.sink = null
                }
            },
        )
        MethodChannel(messenger, "zen/wifi_direct").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "state" -> result.success(state(context))
                    "requestPermissions" -> {
                        val missing = missingPermissions(context)
                        if (missing.isNotEmpty() && activity != null) {
                            ActivityCompat.requestPermissions(
                                activity,
                                missing.toTypedArray(),
                                PERMISSION_REQUEST,
                            )
                        }
                        result.success(missing.isEmpty())
                    }
                    "start" -> {
                        client.active = true
                        result.success(applyActive())
                    }
                    "stop" -> {
                        client.active = false
                        applyActive()
                        result.success(null)
                    }
                    "setAdvert" -> {
                        val value = call.argument<String>("advert")
                        advert = value?.takeIf { it.length <= MAX_ADVERT_CHARS && HEX.matches(it) }
                        publishService()
                        result.success(advert != null)
                    }
                    "discover" -> {
                        val windowMs = (call.argument<Int>("windowMs") ?: 20_000).coerceIn(5_000, 60_000)
                        result.success(discover(windowMs.toLong()))
                    }
                    "createGroup" -> createGroup { ok -> main.post { result.success(ok) } }
                    "joinGroup" -> {
                        val name = call.argument<String>("name")
                        val passphrase = call.argument<String>("passphrase")
                        if (name == null || passphrase == null) {
                            result.success(false)
                        } else {
                            joinGroup(name, passphrase) { ok -> main.post { result.success(ok) } }
                        }
                    }
                    "removeGroup" -> removeGroup { ok -> main.post { result.success(ok) } }
                    else -> result.notImplemented()
                }
            } catch (error: SecurityException) {
                Log.w(TAG, "${call.method}: no permission", error)
                result.success(false)
            } catch (error: Exception) {
                Log.w(TAG, "${call.method} failed", error)
                result.error("wifi_direct", error.message, null)
            }
        }
    }

    private val HEX = Regex("^[0-9a-f]+$")
    private val GROUP_NAME = Regex("^DIRECT-[0-9A-Za-z]{2}-[0-9A-Za-z-]{1,24}$")

    private fun send(event: Map<String, Any?>) {
        main.post {
            for (client in clients) {
                if (!client.active) {
                    continue
                }
                try {
                    client.sink?.success(event)
                } catch (error: Exception) {
                    Log.w(TAG, "Event for a closed engine dropped", error)
                }
            }
        }
    }

    private fun supported(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)

    private fun neededPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun missingPermissions(context: Context): List<String> = neededPermissions().filter {
        ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
    }

    private fun state(context: Context): Map<String, Any?> = mapOf(
        "supported" to supported(context),
        "permitted" to missingPermissions(context).isEmpty(),
        "enabled" to p2pEnabled,
        "wifi" to wifiNetworks.isNotEmpty(),
        "group" to groupMap(group),
    )

    private fun groupMap(value: WifiP2pGroup?): Map<String, Any?>? {
        if (value == null) {
            return null
        }
        return mapOf(
            "owner" to value.isGroupOwner,
            "name" to value.networkName,
            // Only the owner hands it out (in its service record).
            "passphrase" to if (value.isGroupOwner) value.passphrase else null,
            "interface" to value.`interface`,
            "clients" to value.clientList.size,
        )
    }

    /** Starts or stops the radio work: on while any engine wants it. */
    private fun applyActive(): Boolean {
        val context = appContext ?: return false
        val wanted = clients.any { it.active }
        if (!wanted) {
            shutDown(context)
            return true
        }
        if (!supported(context) || missingPermissions(context).isNotEmpty()) {
            return false
        }
        if (manager == null) {
            val p2p = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
                ?: return false
            manager = p2p
            channel = p2p.initialize(context, Looper.getMainLooper()) {
                // The framework dropped the channel; the next start makes a new one.
                manager = null
                channel = null
            }
            watch(context)
            setUpServiceListeners()
        }
        publishService()
        return true
    }

    private fun watch(context: Context) {
        if (receiver == null) {
            val filter = IntentFilter().apply {
                addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            }
            val r = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context?, intent: Intent?) {
                    when (intent?.action) {
                        WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                            p2pEnabled = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1) ==
                                WifiP2pManager.WIFI_P2P_STATE_ENABLED
                            send(mapOf("type" to "p2p", "enabled" to p2pEnabled))
                        }
                        WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> refreshGroup()
                    }
                }
            }
            // Protected system broadcasts: only the system can send them.
            ContextCompat.registerReceiver(context, r, filter, ContextCompat.RECEIVER_EXPORTED)
            receiver = r
        }
        if (wifiCallback == null) {
            val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    main.post {
                        wifiNetworks.add(network)
                        send(mapOf("type" to "wifi", "connected" to true))
                    }
                }

                override fun onLost(network: Network) {
                    main.post {
                        wifiNetworks.remove(network)
                        send(mapOf("type" to "wifi", "connected" to wifiNetworks.isNotEmpty()))
                    }
                }
            }
            // Any Wi-Fi network, with internet or not: friends there are
            // found over it.
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            connectivity.registerNetworkCallback(request, callback)
            wifiCallback = callback
        }
    }

    @SuppressLint("MissingPermission")
    private fun refreshGroup() {
        val p2p = manager ?: return
        val ch = channel ?: return
        try {
            p2p.requestGroupInfo(ch) { info ->
                group = info
                publishService()
                send(mapOf("type" to "group", "group" to groupMap(info)))
            }
        } catch (error: SecurityException) {
            Log.w(TAG, "Group info: no permission", error)
        }
    }

    @SuppressLint("MissingPermission")
    private fun setUpServiceListeners() {
        val p2p = manager ?: return
        val ch = channel ?: return
        p2p.setDnsSdResponseListeners(
            ch,
            { _, _, _ -> },
            { fullDomain, record, device ->
                if (fullDomain?.contains(SERVICE_TYPE) == true && device != null) {
                    val peerAdvert = record?.get("a")
                    if (peerAdvert != null && peerAdvert.length <= MAX_ADVERT_CHARS && HEX.matches(peerAdvert)) {
                        val name = record["n"]?.takeIf { GROUP_NAME.matches(it) }
                        val passphrase = record["p"]?.takeIf { it.length in 8..63 }
                        send(
                            mapOf(
                                "type" to "peer",
                                "device" to device.deviceAddress,
                                "advert" to peerAdvert,
                                "name" to name,
                                "passphrase" to if (name != null) passphrase else null,
                            ),
                        )
                    }
                }
            },
        )
    }

    /** (Re)publishes this phone's service record. */
    @SuppressLint("MissingPermission")
    private fun publishService() {
        val p2p = manager ?: return
        val ch = channel ?: return
        val value = advert ?: return
        val txt = HashMap<String, String>()
        txt["a"] = value
        val current = group
        if (current != null && current.isGroupOwner) {
            txt["n"] = current.networkName
            current.passphrase?.let { txt["p"] = it }
        }
        // A random instance name each time: nothing to follow from one
        // record to the next.
        val instance = "zl" + randomToken(6)
        val info = WifiP2pDnsSdServiceInfo.newInstance(instance, SERVICE_TYPE, txt)
        try {
            p2p.clearLocalServices(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = addService(info)

                override fun onFailure(reason: Int) = addService(info)
            })
        } catch (error: SecurityException) {
            Log.w(TAG, "Service record: no permission", error)
        }
    }

    @SuppressLint("MissingPermission")
    private fun addService(info: WifiP2pDnsSdServiceInfo) {
        val p2p = manager ?: return
        val ch = channel ?: return
        try {
            p2p.addLocalService(ch, info, logged("addLocalService"))
        } catch (error: SecurityException) {
            Log.w(TAG, "Service record: no permission", error)
        }
    }

    @SuppressLint("MissingPermission")
    private fun discover(windowMs: Long): Boolean {
        val p2p = manager ?: return false
        val ch = channel ?: return false
        main.removeCallbacks(stopDiscovery)
        return try {
            p2p.clearServiceRequests(ch, null)
            p2p.addServiceRequest(ch, WifiP2pDnsSdServiceRequest.newInstance(), null)
            p2p.discoverServices(ch, logged("discoverServices"))
            discovering = true
            main.postDelayed(stopDiscovery, windowMs)
            true
        } catch (error: SecurityException) {
            Log.w(TAG, "Discovery: no permission", error)
            false
        }
    }

    private fun endDiscovery() {
        val p2p = manager ?: return
        val ch = channel ?: return
        if (!discovering) {
            return
        }
        discovering = false
        try {
            p2p.clearServiceRequests(ch, null)
            p2p.stopPeerDiscovery(ch, null)
        } catch (error: SecurityException) {
            Log.w(TAG, "Ending discovery: no permission", error)
        }
    }

    @SuppressLint("MissingPermission")
    private fun createGroup(done: (Boolean) -> Unit) {
        val p2p = manager
        val ch = channel
        if (p2p == null || ch == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            done(false)
            return
        }
        val config = WifiP2pConfig.Builder()
            .setNetworkName("DIRECT-zl-" + randomToken(8))
            .setPassphrase(randomToken(20))
            .enablePersistentMode(false)
            .build()
        try {
            p2p.createGroup(ch, config, listener("createGroup", done))
        } catch (error: SecurityException) {
            Log.w(TAG, "Creating a group: no permission", error)
            done(false)
        }
    }

    @SuppressLint("MissingPermission")
    private fun joinGroup(name: String, passphrase: String, done: (Boolean) -> Unit) {
        val p2p = manager
        val ch = channel
        if (p2p == null || ch == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            !GROUP_NAME.matches(name) || passphrase.length !in 8..63
        ) {
            done(false)
            return
        }
        val config = WifiP2pConfig.Builder()
            .setNetworkName(name)
            .setPassphrase(passphrase)
            .enablePersistentMode(false)
            .build()
        try {
            p2p.connect(ch, config, listener("joinGroup", done))
        } catch (error: SecurityException) {
            Log.w(TAG, "Joining a group: no permission", error)
            done(false)
        }
    }

    private fun removeGroup(done: (Boolean) -> Unit) {
        val p2p = manager
        val ch = channel
        if (p2p == null || ch == null) {
            done(true)
            return
        }
        p2p.removeGroup(ch, listener("removeGroup", done))
    }

    /** Everything off: group, record, discovery, listeners. */
    private fun shutDown(context: Context) {
        val p2p = manager
        val ch = channel
        main.removeCallbacks(stopDiscovery)
        if (p2p != null && ch != null) {
            try {
                if (discovering) {
                    p2p.stopPeerDiscovery(ch, null)
                }
                p2p.clearServiceRequests(ch, null)
                p2p.clearLocalServices(ch, null)
                if (group != null) {
                    p2p.removeGroup(ch, null)
                }
            } catch (error: SecurityException) {
                Log.w(TAG, "Shutting down: no permission", error)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                ch.close()
            }
        }
        discovering = false
        group = null
        advert = null
        manager = null
        channel = null
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (error: IllegalArgumentException) {
                Log.w(TAG, "Receiver already gone", error)
            }
        }
        receiver = null
        wifiCallback?.let {
            val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            try {
                connectivity?.unregisterNetworkCallback(it)
            } catch (error: IllegalArgumentException) {
                Log.w(TAG, "Network callback already gone", error)
            }
        }
        wifiCallback = null
        wifiNetworks.clear()
    }

    private fun logged(what: String) = object : WifiP2pManager.ActionListener {
        override fun onSuccess() {}

        override fun onFailure(reason: Int) {
            Log.w(TAG, "$what failed ($reason)")
        }
    }

    private fun listener(what: String, done: (Boolean) -> Unit) = object : WifiP2pManager.ActionListener {
        override fun onSuccess() = done(true)

        override fun onFailure(reason: Int) {
            Log.w(TAG, "$what failed ($reason)")
            done(false)
        }
    }

    private const val ALPHABET = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    private fun randomToken(length: Int): String =
        (1..length).map { ALPHABET[random.nextInt(ALPHABET.length)] }.joinToString("")
}
