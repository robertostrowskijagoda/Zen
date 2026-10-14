package com.roj.zen

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.UUID

/**
 * People nearby over Bluetooth LE (§15), without any plugin:
 *  - advertising: manufacturer data (id 0xFFFF, "ZN" + 16-byte token that
 *    changes every 15 minutes; only friends can tell whose it is);
 *  - scanning: reports every Zen token seen, with signal strength;
 *  - a tiny GATT server with one writable characteristic: someone nearby
 *    can "wave" (leave a short hello with their mesh address) without
 *    either side learning the other's account. Anyone can write to it (no
 *    pairing), so waves are limited per phone here and checked in Dart
 *    (an alarm wave rings only when a friend signed it, §16.3).
 *
 * Advertising is low power, so it can stay on all the time; scanning costs
 * more and runs only while someone asks for it. When Bluetooth is switched
 * off and on again, advertising and scanning start again by themselves
 * and every engine hears a "bluetooth" event.
 *
 * The radio is shared by every Flutter engine that uses it: the app's (with
 * its Activity) and the background service's (no Activity, so it can only
 * report missing permissions). Advertising and scanning run while any
 * engine still wants them; an alarm wave is answered by exactly one engine
 * (§16.3): the background service while it takes them and the app is not on
 * screen, otherwise the app.
 */
object ZenNearbyBridge {
    private const val TAG = "ZenNearby"
    private const val COMPANY_ID = 0xFFFF
    private val MAGIC = byteArrayOf(0x5A, 0x4E)
    private const val PERMISSION_REQUEST = 3201
    private val SERVICE: UUID = UUID.fromString("5a454e00-6e65-6172-6279-000000000001")
    private val WAVE: UUID = UUID.fromString("5a454e00-6e65-6172-6279-000000000002")

    /** One engine using the radio. Touched on the main thread only. */
    private class Client(val engine: FlutterEngine, val activity: FragmentActivity?) {
        val background: Boolean
            get() = activity == null
        var sink: EventChannel.EventSink? = null

        /** The token this engine wants shown (`null`: not visible). */
        var token: ByteArray? = null
        var tokenSetAt = 0L
        var scanning = false
        var lowPower = false

        /** The background service answers alarm waves while the app is away. */
        var alarmReceiver = false
    }

    private val clients = ArrayList<Client>()
    private var appContext: Context? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var advertisedToken: ByteArray? = null
    private var scanCallback: ScanCallback? = null
    private var scanLowPower = false
    private var gattServer: BluetoothGattServer? = null

    /** Prepared (long) writes per phone; touched on binder threads. */
    private val pendingWrites = HashMap<String, ByteArrayOutputStream>()
    private const val MAX_PENDING_WRITERS = 8
    private val main = Handler(Looper.getMainLooper())

    /** Bluetooth on/off, registered once per process. */
    private var stateReceiver: BroadcastReceiver? = null

    /** When waves came (main thread): per phone and in all. */
    private val waveTimes = HashMap<String, ArrayDeque<Long>>()
    private val allWaveTimes = ArrayDeque<Long>()
    private const val WAVE_WINDOW_MS = 60_000L
    private const val MAX_WAVES_PER_PHONE = 6
    private const val MAX_WAVES = 40

    /** The app's engine: permission requests go through its Activity. */
    fun register(engine: FlutterEngine, activity: FragmentActivity) {
        attach(engine, activity.applicationContext, activity)
    }

    /**
     * The background service's engine (§16.3: alarm waves while the app is
     * closed). Without an Activity it cannot ask for permissions.
     */
    fun registerBackground(engine: FlutterEngine, context: Context) {
        attach(engine, context.applicationContext, null)
    }

    /** [engine] is going away: whatever only it wanted stops. */
    fun unregister(engine: FlutterEngine) {
        if (!clients.removeAll { it.engine === engine }) {
            return
        }
        val context = appContext ?: return
        try {
            applyAdvertising(context)
            applyScan(context)
        } catch (error: Exception) {
            Log.w(TAG, "Releasing the radio failed", error)
        }
    }

    private fun attach(engine: FlutterEngine, context: Context, activity: FragmentActivity?) {
        appContext = context
        watchBluetoothState(context)
        clients.removeAll { it.engine === engine }
        val client = Client(engine, activity)
        clients.add(client)
        val messenger = engine.dartExecutor.binaryMessenger
        EventChannel(messenger, "zen/nearby/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    client.sink = sink
                }

                override fun onCancel(arguments: Any?) {
                    client.sink = null
                }
            },
        )
        MethodChannel(messenger, "zen/nearby").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "state" -> result.success(state(context))
                    "requestPermissions" -> {
                        val missing = missingPermissions(context)
                        if (missing.isNotEmpty() && activity != null) {
                            ActivityCompat.requestPermissions(activity, missing.toTypedArray(), PERMISSION_REQUEST)
                        }
                        result.success(missing.isEmpty())
                    }
                    "requestEnable" -> result.success(requestEnable(context, activity))
                    "startAdvertising" -> {
                        val token = call.argument<ByteArray>("token")
                        if (token == null) {
                            result.success(false)
                        } else {
                            client.token = token
                            client.tokenSetAt = SystemClock.elapsedRealtime()
                            result.success(applyAdvertising(context))
                        }
                    }
                    "stopAdvertising" -> {
                        client.token = null
                        applyAdvertising(context)
                        result.success(null)
                    }
                    "startScan" -> {
                        client.scanning = true
                        client.lowPower = call.argument<Boolean>("lowPower") ?: false
                        val ok = applyScan(context)
                        if (!ok) {
                            client.scanning = false
                        }
                        result.success(ok)
                    }
                    "stopScan" -> {
                        client.scanning = false
                        applyScan(context)
                        result.success(null)
                    }
                    "setAlarmReceiver" -> {
                        client.alarmReceiver = call.arguments as? Boolean ?: false
                        result.success(null)
                    }
                    "wave" -> {
                        val device = call.argument<String>("device")
                        val data = call.argument<ByteArray>("data")
                        if (device == null || data == null) {
                            result.success(false)
                        } else {
                            wave(context, device, data) { ok -> main.post { result.success(ok) } }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: SecurityException) {
                Log.w(TAG, "${call.method}: no permission", error)
                result.success(false)
            } catch (error: Exception) {
                Log.w(TAG, "${call.method} failed", error)
                result.error("nearby", error.message, null)
            }
        }
    }

    /** Sends [event] to [client]'s Dart side; a closed engine just misses it. */
    private fun send(client: Client, event: Map<String, Any>) {
        val sink = client.sink ?: return
        try {
            sink.success(event)
        } catch (error: Exception) {
            Log.w(TAG, "Event for a closed engine dropped", error)
        }
    }

    private fun adapter(context: Context): BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun neededPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun missingPermissions(context: Context): List<String> = neededPermissions().filter {
        ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
    }

    private fun state(context: Context): Map<String, Any> {
        val adapter = adapter(context)
        return mapOf(
            "supported" to (adapter != null &&
                context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)),
            "enabled" to (adapter?.isEnabled == true),
            "permitted" to missingPermissions(context).isEmpty(),
            "canAdvertise" to (adapter?.bluetoothLeAdvertiser != null),
            // Android 11 and older: Bluetooth scanning needs the location
            // permission (and location switched on).
            "needsLocation" to (Build.VERSION.SDK_INT < Build.VERSION_CODES.S),
        )
    }

    /**
     * Asks the person to switch Bluetooth on (the system dialog). Returns
     * whether it is on already; the answer comes as a "bluetooth" event.
     * Needs an Activity, and BLUETOOTH_CONNECT on Android 12+.
     */
    @SuppressLint("MissingPermission")
    private fun requestEnable(context: Context, activity: FragmentActivity?): Boolean {
        val adapter = adapter(context) ?: return false
        if (adapter.isEnabled) {
            return true
        }
        if (activity == null) {
            return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        activity.startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
        return false
    }

    /**
     * Restarts advertising and scanning when Bluetooth comes back on (the
     * stack drops both when it goes off), and tells every engine.
     */
    private fun watchBluetoothState(context: Context) {
        if (stateReceiver != null) {
            return
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(received: Context?, intent: Intent?) {
                if (intent == null || intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) {
                    return
                }
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                if (state == BluetoothAdapter.STATE_ON) {
                    main.post { onBluetoothOn(context) }
                } else if (state == BluetoothAdapter.STATE_TURNING_OFF || state == BluetoothAdapter.STATE_OFF) {
                    main.post { onBluetoothOff() }
                }
            }
        }
        try {
            // A protected system broadcast: no other app can send it.
            ContextCompat.registerReceiver(
                context.applicationContext,
                receiver,
                IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                ContextCompat.RECEIVER_EXPORTED,
            )
            stateReceiver = receiver
        } catch (error: Exception) {
            Log.w(TAG, "Watching Bluetooth on/off failed", error)
        }
    }

    private fun onBluetoothOn(context: Context) {
        try {
            applyAdvertising(context)
            applyScan(context)
        } catch (error: Exception) {
            Log.w(TAG, "Restarting the radio failed", error)
        }
        reportBluetooth(true)
    }

    /** The stack forgot advertising, scanning and the GATT server. */
    private fun onBluetoothOff() {
        advertiseCallback = null
        advertisedToken = null
        scanCallback = null
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        gattServer = null
        synchronized(pendingWrites) {
            pendingWrites.clear()
        }
        reportBluetooth(false)
    }

    /** What the engines were last told (TURNING_OFF and OFF both come). */
    private var reportedOn: Boolean? = null

    private fun reportBluetooth(on: Boolean) {
        if (reportedOn == on) {
            return
        }
        reportedOn = on
        val event = mapOf("type" to "bluetooth", "on" to on)
        for (client in clients.toList()) {
            send(client, event)
        }
    }

    /**
     * Shows the newest wanted token while any engine wants to be visible (both
     * engines compute the same one; restarting for an equal token is skipped).
     */
    private fun applyAdvertising(context: Context): Boolean {
        val token = clients.filter { it.token != null }.maxByOrNull { it.tokenSetAt }?.token
        if (token == null) {
            stopAdvertising(context)
            return true
        }
        val shown = advertisedToken
        if (advertiseCallback != null && shown != null && shown.contentEquals(token)) {
            return true
        }
        return startAdvertising(context, token)
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising(context: Context, token: ByteArray): Boolean {
        val adapter = adapter(context) ?: return false
        if (!adapter.isEnabled || missingPermissions(context).isNotEmpty()) {
            return false
        }
        val advertiser = adapter.bluetoothLeAdvertiser ?: return false
        stopAdvertising(context)
        ensureGattServer(context)
        // Low power (about once a second): cheap enough to stay on all the
        // time; phones looking around still see it within a few seconds.
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addManufacturerData(COMPANY_ID, MAGIC + token.copyOf(16))
            .build()
        val callback = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                Log.w(TAG, "Advertising failed: $errorCode")
                val failed = this
                // Tried again on the next request instead of looking shown.
                main.post {
                    if (advertiseCallback === failed) {
                        advertisedToken = null
                    }
                }
            }
        }
        advertiser.startAdvertising(settings, data, callback)
        advertiseCallback = callback
        advertisedToken = token.copyOf()
        return true
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising(context: Context) {
        advertisedToken = null
        val callback = advertiseCallback ?: return
        advertiseCallback = null
        try {
            adapter(context)?.bluetoothLeAdvertiser?.stopAdvertising(callback)
        } catch (_: Exception) {
        }
    }

    /**
     * Scans while any engine wants it; in low-power mode only when every one
     * of them is fine with it (the background look around, §15).
     */
    private fun applyScan(context: Context): Boolean {
        val wanted = clients.filter { it.scanning }
        if (wanted.isEmpty()) {
            stopScan(context)
            return true
        }
        val lowPower = wanted.all { it.lowPower }
        if (scanCallback != null && scanLowPower == lowPower) {
            return true
        }
        return startScan(context, lowPower)
    }

    @SuppressLint("MissingPermission")
    private fun startScan(context: Context, lowPower: Boolean): Boolean {
        val adapter = adapter(context) ?: return false
        if (!adapter.isEnabled || missingPermissions(context).isNotEmpty()) {
            return false
        }
        val scanner = adapter.bluetoothLeScanner ?: return false
        stopScan(context)
        val filter = ScanFilter.Builder()
            .setManufacturerData(COMPANY_ID, MAGIC, byteArrayOf(0xFF.toByte(), 0xFF.toByte()))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(if (lowPower) ScanSettings.SCAN_MODE_LOW_POWER else ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                report(result)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { report(it) }
            }

            override fun onScanFailed(errorCode: Int) {
                Log.w(TAG, "Scan failed: $errorCode")
            }
        }
        scanner.startScan(listOf(filter), settings, callback)
        scanCallback = callback
        scanLowPower = lowPower
        return true
    }

    private fun report(result: ScanResult) {
        val data = result.scanRecord?.getManufacturerSpecificData(COMPANY_ID) ?: return
        if (data.size < 18 || data[0] != MAGIC[0] || data[1] != MAGIC[1]) {
            return
        }
        val event = mapOf(
            "type" to "seen",
            "token" to data.copyOfRange(2, 18),
            "rssi" to result.rssi,
            "device" to result.device.address,
        )
        main.post {
            // Only engines that are looking around hear who is near.
            for (client in clients.toList()) {
                if (client.scanning) {
                    send(client, event)
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopScan(context: Context) {
        val callback = scanCallback ?: return
        scanCallback = null
        try {
            adapter(context)?.bluetoothLeScanner?.stopScan(callback)
        } catch (_: Exception) {
        }
    }

    @SuppressLint("MissingPermission")
    private fun ensureGattServer(context: Context) {
        if (gattServer != null) {
            return
        }
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: return
        var server: BluetoothGattServer? = null
        server = manager.openGattServer(
            context.applicationContext,
            object : BluetoothGattServerCallback() {
                override fun onCharacteristicWriteRequest(
                    device: BluetoothDevice,
                    requestId: Int,
                    characteristic: BluetoothGattCharacteristic,
                    preparedWrite: Boolean,
                    responseNeeded: Boolean,
                    offset: Int,
                    value: ByteArray?,
                ) {
                    val bytes = value ?: ByteArray(0)
                    if (characteristic.uuid != WAVE || bytes.size > 600) {
                        if (responseNeeded) {
                            server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                        }
                        return
                    }
                    if (preparedWrite) {
                        // A few phones at a time: unanswered long writes
                        // from many addresses must not pile up.
                        val accepted = synchronized(pendingWrites) {
                            val known = pendingWrites[device.address]
                            if (known == null && pendingWrites.size >= MAX_PENDING_WRITERS) {
                                false
                            } else {
                                val buffer = known ?: ByteArrayOutputStream().also {
                                    pendingWrites[device.address] = it
                                }
                                if (buffer.size() + bytes.size <= 1024) {
                                    buffer.write(bytes)
                                }
                                true
                            }
                        }
                        if (!accepted) {
                            if (responseNeeded) {
                                server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                            }
                            return
                        }
                    } else {
                        deliverWave(device.address, bytes)
                    }
                    if (responseNeeded) {
                        server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, bytes)
                    }
                }

                override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
                    val buffer = synchronized(pendingWrites) { pendingWrites.remove(device.address) }
                    if (execute && buffer != null) {
                        deliverWave(device.address, buffer.toByteArray())
                    }
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
            },
        )
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                WAVE,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            ),
        )
        server?.addService(service)
        gattServer = server
    }

    private fun deliverWave(device: String, data: ByteArray) {
        main.post { dispatchWave(device, data) }
    }

    /**
     * Whether a wave from [device] is taken now: a few per phone and some
     * dozens in all per minute (anyone nearby can write, and a phone can
     * change its address). Main thread only.
     */
    private fun allowWave(device: String): Boolean {
        val now = SystemClock.elapsedRealtime()
        while (allWaveTimes.isNotEmpty() && now - allWaveTimes.first() > WAVE_WINDOW_MS) {
            allWaveTimes.removeFirst()
        }
        val iterator = waveTimes.entries.iterator()
        while (iterator.hasNext()) {
            val times = iterator.next().value
            while (times.isNotEmpty() && now - times.first() > WAVE_WINDOW_MS) {
                times.removeFirst()
            }
            if (times.isEmpty()) {
                iterator.remove()
            }
        }
        val mine = waveTimes.getOrPut(device) { ArrayDeque() }
        if (mine.size >= MAX_WAVES_PER_PHONE || allWaveTimes.size >= MAX_WAVES) {
            return false
        }
        mine.addLast(now)
        allWaveTimes.addLast(now)
        return true
    }

    /**
     * Every engine gets the wave; "elsewhere" tells it that the other engine
     * answers alarm waves, so an alarm rings once (§16.3).
     */
    private fun dispatchWave(device: String, data: ByteArray) {
        if (!allowWave(device)) {
            Log.w(TAG, "Too many waves: one dropped")
            return
        }
        val serviceTakesAlarms = !MainActivity.isResumed &&
            clients.any { it.background && it.alarmReceiver && it.sink != null }
        for (client in clients.toList()) {
            val elsewhere = if (client.background) !serviceTakesAlarms else serviceTakesAlarms
            send(
                client,
                mapOf("type" to "wave", "device" to device, "data" to data, "elsewhere" to elsewhere),
            )
        }
    }

    /** Leaves a short hello on a phone nearby (connect, write, disconnect). */
    @SuppressLint("MissingPermission")
    private fun wave(context: Context, address: String, data: ByteArray, done: (Boolean) -> Unit) {
        val adapter = adapter(context)
        if (adapter == null || !adapter.isEnabled || missingPermissions(context).isNotEmpty()) {
            done(false)
            return
        }
        val device = adapter.getRemoteDevice(address)
        var finished = false
        fun finish(gatt: BluetoothGatt?, ok: Boolean) {
            if (finished) return
            finished = true
            try {
                gatt?.disconnect()
                gatt?.close()
            } catch (_: Exception) {
            }
            done(ok)
        }
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    if (!gatt.requestMtu(517)) {
                        gatt.discoverServices()
                    }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    finish(gatt, false)
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                gatt.discoverServices()
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                val characteristic = gatt.getService(SERVICE)?.getCharacteristic(WAVE)
                if (characteristic == null) {
                    finish(gatt, false)
                    return
                }
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeCharacteristic(
                        characteristic,
                        data,
                        BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                    ) == BluetoothGatt.GATT_SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    characteristic.value = data
                    @Suppress("DEPRECATION")
                    gatt.writeCharacteristic(characteristic)
                }
                if (!started) {
                    finish(gatt, false)
                }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                finish(gatt, status == BluetoothGatt.GATT_SUCCESS)
            }
        }
        val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, callback)
        }
        main.postDelayed({ finish(gatt, false) }, 15000)
    }
}
