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
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * People nearby over Bluetooth LE, without any plugin:
 *  - advertising: manufacturer data (id 0xFFFF, "ZN" + 16-byte token +
 *    4-byte hint; a new token every 10 minutes, and advertising restarts
 *    with it, so the Bluetooth address changes together with the token;
 *    only friends can tell whose it is). An engine either hands the token
 *    of now (the app, which works it out itself) or a schedule of tokens
 *    worked out in advance, one per slot (the background service, which
 *    has no key to work them out): the schedule is followed here, with a
 *    restart at each slot boundary, without waking Dart, and nothing is
 *    shown once it is over (never a stale token);
 *  - scanning: reports every Zen token seen (and its hint), with signal
 *    strength;
 *  - a tiny GATT server with one writable characteristic: someone nearby
 *    can "wave" (leave a short hello with their mesh address) without
 *    either side learning the other's account. Anyone can write to it (no
 *    pairing), so waves are limited per phone here and checked in Dart
 *    (an alarm wave rings only when a friend signed it). An alarm
 *    wave signed with a friend's key (handed over by Dart as a pair key
 *    "p:…") is checked here too and counted apart, so a flood of other waves from
 *    changing addresses cannot crowd it out.
 *
 * Advertising is low power, so it can stay on all the time; scanning costs
 * more and runs only while someone asks for it: fully while "W pobliżu" is
 * open, otherwise in short low-power windows (a few seconds every five
 * minutes, decided in Dart from the battery, battery saver and Doze that
 * [state] reports), with results batched in the controller where the
 * phone can, and flushed when the window ends. When Bluetooth is switched
 * off and on again, advertising and scanning start again by themselves
 * and every engine hears a "bluetooth" event.
 *
 * The radio is shared by every Flutter engine that uses it: the app's (with
 * its Activity) and the background service's (no Activity, so it can only
 * report missing permissions). Advertising and scanning run while any
 * engine still wants them; an alarm wave is answered by exactly one engine:
 * the background service while it takes them (it does only while it runs
 * the node, i.e. while the app is locked or closed — on screen behind its
 * lock screen the app could not answer them either), otherwise the app.
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

        /**
         * Tokens worked out in advance, [ADVERT_BYTES] each, for the slots
         * from [scheduleStart] on (`null`: none); used instead of [token].
         */
        var schedule: ByteArray? = null
        var scheduleStart = 0L
        var tokenSetAt = 0L
        var scanning = false
        var lowPower = false

        /** The background service answers alarm waves while the app is away. */
        var alarmReceiver = false

        /**
         * Friends' alarm keys this engine knows: "p:" + a pair key
         * (base64url).
         */
        var alarmKeys: List<String> = emptyList()
    }

    private val clients = ArrayList<Client>()
    private var appContext: Context? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var advertisedToken: ByteArray? = null
    private var scanCallback: ScanCallback? = null
    private var scanLowPower = false

    /** Whether the low-power scan running now batches its results. */
    private var scanBatched = false

    /** How long a low-power scan may hold results back (batched). */
    private const val LOW_POWER_REPORT_DELAY_MS = 3_000L
    private var gattServer: BluetoothGattServer? = null

    /** Prepared (long) writes per phone; touched on binder threads. */
    private val pendingWrites = HashMap<String, ByteArrayOutputStream>()
    private const val MAX_PENDING_WRITERS = 8
    private val main = Handler(Looper.getMainLooper())

    /** Bluetooth on/off, registered once per process. */
    private var stateReceiver: BroadcastReceiver? = null

    /** The next token change of a schedule (main thread). */
    private var rotation: Runnable? = null

    /** When waves came (main thread): per phone and in all. */
    private val waveTimes = HashMap<String, ArrayDeque<Long>>()
    private val allWaveTimes = ArrayDeque<Long>()
    private const val WAVE_WINDOW_MS = 60_000L
    // A hello or an answer is a few writes: its post-quantum key or
    // ciphertext goes in parts (nearby_crypto.dart, kNearbyMaxParts).
    private const val MAX_WAVES_PER_PHONE = 16
    private const val MAX_WAVES = 120

    /**
     * Alarm waves whose friend signature checked out (main thread): their
     * own budget per friend (the key that signed), apart from [MAX_WAVES] and
     * apart from every other friend, so neither a flood of unsigned waves nor
     * one noisy friend can drown another friend's real alarm. Each wave is
     * let through once per [WAVE_WINDOW_MS] (a recorded wave played back from
     * many addresses costs nothing more).
     */
    private val verifiedWaves = HashMap<String, ArrayDeque<Pair<Long, String>>>()
    private const val MAX_VERIFIED_WAVES_PER_FRIEND = 12

    /**
     * Must match `kAlarmWaveVersion`, `kAlarmWaveFreshFor`, `kNearbySlot`,
     * `kNearbyPairKeyPrefix` and `kNearbyHintLength` in Dart.
     */
    private const val ALARM_WAVE_VERSION = 6
    private const val ALARM_WAVE_FRESH_MS = 10 * 60_000L
    private const val NEARBY_SLOT_MS = 10 * 60_000L
    private const val PAIR_KEY_PREFIX = "p:"
    private const val TOKEN_BYTES = 16
    private const val HINT_BYTES = 4
    private const val ADVERT_BYTES = TOKEN_BYTES + HINT_BYTES

    /** A schedule holds at most this many slots (two weeks). */
    private const val MAX_SCHEDULE_SLOTS = 2016

    /** After a slot boundary, so the new slot has surely begun. */
    private const val ROTATION_MARGIN_MS = 500L

    /** The alarm of the token's change, and how long it holds the phone awake. */
    private const val ROTATION_ALARM = "nearby-rotation"
    private const val ROTATION_HOLD_MS = 5_000L
    private const val MAX_ALARM_KEYS = 4096
    private val ALARM_ID = Regex("^[0-9A-Za-z_-]{1,40}$")
    private val HEX32 = Regex("^[0-9a-f]{32}$")

    /**
     * Friends' alarm-wave tokens (hex: pair ids per [NEARBY_SLOT_MS]) around
     * now → the pair key that checks the wave. Rebuilt when the slot or the
     * keys change.
     */
    private var tokenKeys: Map<String, ByteArray> = emptyMap()
    private var tokenKeysEpoch = Long.MIN_VALUE

    /** The app's engine: permission requests go through its Activity. */
    fun register(engine: FlutterEngine, activity: FragmentActivity) {
        attach(engine, activity.applicationContext, activity)
    }

    /**
     * The background service's engine (alarm waves while the app is
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
        tokenKeysEpoch = Long.MIN_VALUE
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
        tokenKeysEpoch = Long.MIN_VALUE
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
                            client.schedule = null
                            client.tokenSetAt = SystemClock.elapsedRealtime()
                            result.success(applyAdvertising(context))
                        }
                    }
                    "startAdvertisingSchedule" -> {
                        val start = call.argument<Number>("start")?.toLong()
                        val adverts = call.argument<ByteArray>("adverts")
                        if (start == null ||
                            adverts == null ||
                            adverts.isEmpty() ||
                            adverts.size % ADVERT_BYTES != 0 ||
                            adverts.size / ADVERT_BYTES > MAX_SCHEDULE_SLOTS
                        ) {
                            result.success(false)
                        } else {
                            // Kept also while Bluetooth is off: shown once
                            // it is back on.
                            client.token = null
                            client.schedule = adverts.copyOf()
                            client.scheduleStart = start
                            client.tokenSetAt = SystemClock.elapsedRealtime()
                            result.success(applyAdvertising(context))
                        }
                    }
                    "stopAdvertising" -> {
                        client.token = null
                        client.schedule = null
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
                    "setAlarmKeys" -> {
                        val keys = (call.arguments as? List<*>)
                            ?.filterIsInstance<String>()
                            ?.filter { it.length <= 64 }
                            ?.distinct()
                            ?.take(MAX_ALARM_KEYS)
                            ?: emptyList()
                        client.alarmKeys = keys
                        tokenKeysEpoch = Long.MIN_VALUE
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

    /** Also what Bluetooth links need ([ZenBluetoothLinkBridge]). */
    internal fun missingPermissions(context: Context): List<String> = neededPermissions().filter {
        ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
    }

    private fun state(context: Context): Map<String, Any> {
        val adapter = adapter(context)
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val battery = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val level = battery?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        return mapOf(
            // The background look around skips low battery, battery saver
            // and Doze (Dart's NearbyLookPolicy); -1: unknown.
            "battery" to level,
            "charging" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && battery?.isCharging == true),
            "powerSave" to (power?.isPowerSaveMode == true),
            "idle" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && power?.isDeviceIdleMode == true),
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
     * What [client] wants shown now: its token, or its schedule's token of
     * the current slot (`null` before or past the schedule).
     */
    private fun wantedAdvert(client: Client): ByteArray? {
        val schedule = client.schedule ?: return client.token
        val index = System.currentTimeMillis() / NEARBY_SLOT_MS - client.scheduleStart
        if (index < 0 || index >= schedule.size / ADVERT_BYTES) {
            return null
        }
        val from = index.toInt() * ADVERT_BYTES
        return schedule.copyOfRange(from, from + ADVERT_BYTES)
    }

    /**
     * While any engine follows a schedule, applies it again right after the
     * next slot boundary. An exact alarm that wakes the phone (nothing holds
     * it awake in between), so a token never stays on air past its slot.
     */
    private fun scheduleRotation(context: Context) {
        if (rotation != null) {
            ZenPower.cancel(context, ROTATION_ALARM)
        }
        rotation = null
        if (clients.none { it.schedule != null }) {
            return
        }
        val now = System.currentTimeMillis()
        val next = (now / NEARBY_SLOT_MS + 1) * NEARBY_SLOT_MS
        val task = Runnable {
            rotation = null
            try {
                applyAdvertising(context)
            } catch (error: Exception) {
                Log.w(TAG, "Changing the token failed", error)
            }
        }
        rotation = task
        ZenPower.scheduleNative(
            context,
            ROTATION_ALARM,
            next - now + ROTATION_MARGIN_MS,
            exact = true,
            holdMs = ROTATION_HOLD_MS,
        ) { task.run() }
    }

    /**
     * Shows the newest wanted token while any engine wants to be visible (both
     * engines compute the same one; restarting for an equal token is skipped).
     */
    private fun applyAdvertising(context: Context): Boolean {
        scheduleRotation(context)
        val token = clients
            .mapNotNull { client -> wantedAdvert(client)?.let { client.tokenSetAt to it } }
            .maxByOrNull { it.first }
            ?.second
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
            // Token and hint (20 bytes).
            .addManufacturerData(
                COMPANY_ID,
                MAGIC + token.copyOf(token.size.coerceIn(TOKEN_BYTES, TOKEN_BYTES + HINT_BYTES)),
            )
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
     * of them is fine with it (the background look around).
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
        // A short low-power look lets the controller batch what it hears
        // (the CPU and Dart are woken once per batch, not per advert); the
        // batch is flushed when the look ends ([stopScan]).
        val batched = lowPower && adapter.isOffloadedScanBatchingSupported
        val builder = ScanSettings.Builder()
            .setScanMode(if (lowPower) ScanSettings.SCAN_MODE_LOW_POWER else ScanSettings.SCAN_MODE_LOW_LATENCY)
        if (batched) {
            builder.setReportDelay(LOW_POWER_REPORT_DELAY_MS)
        }
        val settings = builder.build()
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
        scanBatched = batched
        return true
    }

    private fun report(result: ScanResult) {
        val data = result.scanRecord?.getManufacturerSpecificData(COMPANY_ID) ?: return
        if (data.size < 2 + TOKEN_BYTES + HINT_BYTES || data[0] != MAGIC[0] || data[1] != MAGIC[1]) {
            return
        }
        val event = HashMap<String, Any>()
        event["type"] = "seen"
        event["token"] = data.copyOfRange(2, 2 + TOKEN_BYTES)
        event["hint"] = data.copyOfRange(2 + TOKEN_BYTES, 2 + TOKEN_BYTES + HINT_BYTES)
        event["rssi"] = result.rssi
        event["device"] = result.device.address
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
        val batched = scanBatched
        scanBatched = false
        try {
            val scanner = adapter(context)?.bluetoothLeScanner
            if (batched) {
                // What the controller still holds comes now (Dart takes it
                // for a few seconds after the look).
                scanner?.flushPendingScanResults(callback)
            }
            scanner?.stopScan(callback)
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
     * Whether an alarm wave whose friend signature checked out ([mac], signed
     * by the friend [sender]) is taken now: [MAX_VERIFIED_WAVES_PER_FRIEND]
     * per minute for that friend, apart from everything else. `null`: that
     * friend's budget is spent (the wave may still go through the one for
     * anyone); `false`: this very wave went through within the window
     * already (played back), so it is dropped. Main thread only.
     */
    private fun allowVerifiedWave(sender: String, mac: String): Boolean? {
        val now = SystemClock.elapsedRealtime()
        val iterator = verifiedWaves.entries.iterator()
        while (iterator.hasNext()) {
            val times = iterator.next().value
            while (times.isNotEmpty() && now - times.first().first > WAVE_WINDOW_MS) {
                times.removeFirst()
            }
            if (times.isEmpty()) {
                iterator.remove()
            }
        }
        val mine = verifiedWaves.getOrPut(sender) { ArrayDeque() }
        if (mine.any { it.second == mac }) {
            return false
        }
        if (mine.size >= MAX_VERIFIED_WAVES_PER_FRIEND) {
            return null
        }
        mine.addLast(now to mac)
        return true
    }

    private fun hmac(key: ByteArray, text: String): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(text.toByteArray(Charsets.UTF_8))
    }

    private fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            out.append("0123456789abcdef"[v ushr 4]).append("0123456789abcdef"[v and 0x0F])
        }
        return out.toString()
    }

    /**
     * Friends' alarm-wave tokens around now, rebuilt when the slot or the
     * keys change. A fresh wave (dated within [ALARM_WAVE_FRESH_MS] of now)
     * carries the pair's id, as Dart's `nearbyPairId`:
     * HMAC-SHA256(pairKey, "zen-nearby-pair-id|<slot>"), first 16 bytes.
     */
    private fun friendTokens(): Map<String, ByteArray> {
        val slot = System.currentTimeMillis() / NEARBY_SLOT_MS
        if (slot == tokenKeysEpoch) {
            return tokenKeys
        }
        val map = HashMap<String, ByteArray>()
        for (entry in clients.flatMap { it.alarmKeys }.distinct()) {
            if (!entry.startsWith(PAIR_KEY_PREFIX)) {
                continue
            }
            val key = try {
                Base64.decode(entry.removePrefix(PAIR_KEY_PREFIX), Base64.URL_SAFE or Base64.NO_WRAP)
            } catch (_: IllegalArgumentException) {
                continue
            }
            if (key.isEmpty()) {
                continue
            }
            for (s in slot - 2..slot + 2) {
                map[hex(hmac(key, "zen-nearby-pair-id|$s").copyOf(16))] = key
            }
        }
        tokenKeys = map
        tokenKeysEpoch = slot
        return map
    }

    /**
     * Who signed [data] (a short id of the friend's key) and the signature,
     * when it is a fresh alarm wave signed with the key of a friend some
     * engine knows (the same check as Dart's `AlarmWave.verify`), else
     * `null`. Dart checks it again (and who the friend is) before anything
     * rings; this only decides which budget the wave is counted against.
     */
    private fun verifiedAlarmMac(data: ByteArray): Pair<String, String>? {
        if (data.isEmpty() || data[0] != '{'.code.toByte()) {
            return null
        }
        val keys = friendTokens()
        if (keys.isEmpty()) {
            return null
        }
        try {
            val json = JSONObject(String(data, Charsets.UTF_8))
            val version = json.opt("v")
            if (version != ALARM_WAVE_VERSION) {
                return null
            }
            val id = json.opt("id") as? String ?: return null
            val at = when (val raw = json.opt("at")) {
                is Int -> raw.toLong()
                is Long -> raw
                else -> return null
            }
            val ended = when (val end = json.opt("end")) {
                null, JSONObject.NULL -> false
                is Boolean -> end
                else -> return null
            }
            val token = json.opt("t") as? String ?: return null
            val mac = json.opt("m") as? String ?: return null
            if (!ALARM_ID.matches(id) || !HEX32.matches(token) || !HEX32.matches(mac)) {
                return null
            }
            if (Math.abs(System.currentTimeMillis() - at) > ALARM_WAVE_FRESH_MS) {
                return null
            }
            val key = keys[token] ?: return null
            // The pair's id must be the one of the wave's own slot.
            if (hex(hmac(key, "zen-nearby-pair-id|${at / NEARBY_SLOT_MS}").copyOf(16)) != token) {
                return null
            }
            val expected = hex(
                hmac(
                    key,
                    "zen-nearby-alarm|$ALARM_WAVE_VERSION|$id|$at|${if (ended) 1 else 0}|$token",
                ).copyOf(16),
            )
            val same = MessageDigest.isEqual(
                expected.toByteArray(Charsets.US_ASCII),
                mac.toByteArray(Charsets.US_ASCII),
            )
            return if (same) {
                hex(MessageDigest.getInstance("SHA-256").digest(key).copyOf(8)) to mac
            } else {
                null
            }
        } catch (_: Exception) {
            return null
        }
    }

    /**
     * Every engine gets the wave; "elsewhere" tells it that the other engine
     * answers alarm waves, so an alarm rings once. A friend's signed
     * alarm wave is checked first and counted apart ([allowVerifiedWave]);
     * anything else goes through the limits per phone and in all.
     */
    private fun dispatchWave(device: String, data: ByteArray) {
        val signed = verifiedAlarmMac(data)
        val verified = if (signed == null) null else allowVerifiedWave(signed.first, signed.second)
        if (verified == false) {
            return // the same signed wave went through a moment ago
        }
        if (verified == null && !allowWave(device)) {
            Log.w(TAG, "Too many waves: one dropped")
            return
        }
        val serviceTakesAlarms =
            clients.any { it.background && it.alarmReceiver && it.sink != null }
        // A friend's alarm (or a hello) is answered by Dart: the phone stays
        // awake for it (nothing else holds it).
        appContext?.let { ZenPower.hold(it, "nearby-wave", 30_000) }
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
