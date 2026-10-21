package com.roj.zen

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.BluetoothStatusCodes
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
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Bluetooth links with friends nearby (item 6; `zen/bt_link` + events
 * on `zen/bt_link/events`). Dart decides whom to link with
 * (native_stream_local_link.dart); this file drives the radio and pumps
 * each Bluetooth stream into the endpoint the Go bridge gave Dart: it
 * connects to 127.0.0.1:port, writes the 16-byte token, then copies both
 * ways until either side closes. The bridge's handshake proves the pair
 * and refuses everyone else, so a stream from anyone is safe to hand over.
 *
 * The format every platform shares (bluetooth_link.go):
 *  - BLE advertising (Android 10+): the Zen link service UUID in the
 *    packet, and in the scan response manufacturer data of company 0xFFFF:
 *    "ZL", the L2CAP PSM (uint16 little-endian) and the bridge's advert
 *    (23 bytes, a 16-byte Bloom filter: 31 bytes in all, the legacy
 *    limit). A GATT service gives the same advert and PSM to devices that
 *    read them (iPhones advertise only the service UUID; this side reads
 *    theirs over GATT before connecting).
 *  - Streams: BLE L2CAP connection-oriented channels (Android 10+,
 *    without pairing), and classic RFCOMM (insecure) with devices paired
 *    in the system settings (computers running Zen on Windows, phones on
 *    Android 9 and older), under the Zen RFCOMM service class.
 *  - GATT streams, for Windows (no BLE L2CAP channels there): …0005 is
 *    written with response by the GATT client, …0006 notified by the
 *    server; an empty value ends the stream. This GATT server takes them
 *    (a client subscribing to …0006 opens one), and a device whose GATT
 *    service has both but no PSM (a Windows computer) is reached as a
 *    GATT client.
 *
 * Permissions are the ones of people nearby ([ZenNearbyBridge]). Battery:
 * advertising and scanning run only in the windows Dart asks for; the
 * listeners themselves cost nothing on the air. Both the app's engine and
 * the background service's may use it; streams and adverts go to the one
 * that started last.
 */
object ZenBluetoothLinkBridge {
    private const val TAG = "ZenBtLink"
    private const val PERMISSION_REQUEST = 3501
    private val SERVICE: UUID = UUID.fromString("5a454e00-6c69-6e6b-0000-000000000001")
    private val ADVERT: UUID = UUID.fromString("5a454e00-6c69-6e6b-0000-000000000002")
    private val PSM: UUID = UUID.fromString("5a454e00-6c69-6e6b-0000-000000000003")
    private val RFCOMM: UUID = UUID.fromString("5a454e00-6c69-6e6b-0000-000000000004")
    private val STREAM_IN: UUID = UUID.fromString("5a454e00-6c69-6e6b-0000-000000000005")
    private val STREAM_OUT: UUID = UUID.fromString("5a454e00-6c69-6e6b-0000-000000000006")
    private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    private const val COMPANY_ID = 0xFFFF
    private val MAGIC = byteArrayOf(0x5A, 0x4C)

    /** The Bloom filter bytes Dart asks the bridge for. */
    private const val ADVERT_BYTES = 16

    /** The advert in the scan response: a 7-byte header and the filter. */
    private const val MAX_RESPONSE_ADVERT = 7 + ADVERT_BYTES
    private const val MIN_ADVERT = 7 + 8
    private const val MAX_ADVERT = 7 + 1024
    private const val TOKEN_BYTES = 16
    private const val MAX_INCOMING = 8
    // Incoming streams waiting from one device at once (one device must not
    // take every slot).
    private const val MAX_INCOMING_PER_DEVICE = 2
    private const val MAX_STREAMS = 16
    private const val INCOMING_WAIT_MS = 15_000L
    private const val LOOPBACK_WAIT_MS = 5_000
    private const val GATT_READ_MS = 10_000L
    private const val GATT_REREAD_MS = 120_000L
    private const val GATT_CONNECT_MS = 20_000L
    private const val GATT_WRITE_MS = 10_000L
    private const val GATT_MTU = 517
    // GATT values a stream keeps while it waits for Dart's endpoint.
    private const val MAX_GATT_QUEUED = 512
    private const val SEEN_EVERY_MS = 3_000L
    private const val BUFFER = 8192
    private const val MAX_SEEN = 512
    private val HEX = Regex("^([0-9a-f]{2})+$")

    private class Client(val engine: FlutterEngine, val activity: FragmentActivity?) {
        var sink: EventChannel.EventSink? = null
        var active = false
        var since = 0L
    }

    /** One stream pumped into the bridge. */
    private class Pipe(val device: String, val bt: Closeable, val loop: Socket) {
        @Volatile
        private var closed = false

        fun close() {
            if (closed) return
            closed = true
            try {
                bt.close()
            } catch (_: Exception) {
            }
            try {
                loop.close()
            } catch (_: Exception) {
            }
        }
    }

    /**
     * A byte stream over the Zen service's stream characteristics. [send]
     * hands the radio one piece of at most [mtu] - 3 bytes and waits until
     * it took it; values from the radio wait in [inbound] (an empty array
     * ends the stream).
     */
    private class GattPipe(val device: String) : Closeable {
        val inbound = LinkedBlockingQueue<ByteArray>()

        @Volatile
        var mtu = 23

        @Volatile
        var closed = false
            private set
        var send: (ByteArray) -> Boolean = { false }
        var onClose: () -> Unit = {}

        fun received(value: ByteArray) {
            if (closed) return
            if (value.isEmpty() || inbound.size >= MAX_GATT_QUEUED) {
                close()
                return
            }
            inbound.offer(value)
        }

        override fun close() {
            synchronized(this) {
                if (closed) return
                closed = true
            }
            inbound.offer(ByteArray(0))
            try {
                onClose()
            } catch (_: Exception) {
            }
        }
    }

    private val clients = ArrayList<Client>()
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()
    private val random = SecureRandom()
    private var appContext: Context? = null
    private var stateReceiver: BroadcastReceiver? = null

    // Main thread, except where marked.
    private var l2capServer: BluetoothServerSocket? = null
    private var rfcommServer: BluetoothServerSocket? = null
    /** Read by notifications on worker threads. */
    @Volatile
    private var gattServer: BluetoothGattServer? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null
    private val stopScanning = Runnable { appContext?.let { stopScan(it) } }

    /** Read by GATT requests on binder threads. */
    @Volatile
    private var psm = 0

    @Volatile
    private var advert = ByteArray(0)

    /** Devices seen in scans (they keep their address type). */
    private val seen = HashMap<String, BluetoothDevice>()
    private val seenAt = HashMap<String, Long>()
    private val gattReadAt = HashMap<String, Long>()
    private var gattBusy = false

    /** Incoming streams waiting for Dart's endpoint, and pumped streams. */
    private val incoming = ConcurrentHashMap<String, Pair<String, Closeable>>()
    private val streams = ConcurrentHashMap<String, Pipe>()

    /** GATT streams clients opened to this device's server, by address. */
    private val gattServerPipes = ConcurrentHashMap<String, GattPipe>()
    private val gattMtus = ConcurrentHashMap<String, Int>()
    private val notifyLock = Any()
    private val notifySent = Semaphore(0)

    fun register(engine: FlutterEngine, activity: FragmentActivity) {
        attach(engine, activity.applicationContext, activity)
    }

    fun registerBackground(engine: FlutterEngine, context: Context) {
        attach(engine, context.applicationContext, null)
    }

    fun unregister(engine: FlutterEngine) {
        if (clients.removeAll { it.engine === engine }) {
            appContext?.let { applyActive(it) }
        }
    }

    private fun attach(engine: FlutterEngine, context: Context, activity: FragmentActivity?) {
        appContext = context
        clients.removeAll { it.engine === engine }
        val client = Client(engine, activity)
        clients.add(client)
        val messenger = engine.dartExecutor.binaryMessenger
        EventChannel(messenger, "zen/bt_link/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    client.sink = sink
                }

                override fun onCancel(arguments: Any?) {
                    client.sink = null
                }
            },
        )
        MethodChannel(messenger, "zen/bt_link").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "state" -> result.success(state(context))
                    "requestPermissions" -> {
                        val missing = ZenNearbyBridge.missingPermissions(context)
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
                        client.since = SystemClock.elapsedRealtime()
                        result.success(startServers(context))
                    }
                    "stop" -> {
                        client.active = false
                        applyActive(context)
                        result.success(null)
                    }
                    "advertise" -> {
                        val bytes = unhex(call.argument<String>("advert"))
                        val windowMs = (call.argument<Int>("windowMs") ?: 20_000).coerceIn(1_000, 180_000)
                        result.success(
                            bytes != null && owner() === client &&
                                advertise(context, bytes, windowMs),
                        )
                    }
                    "scan" -> {
                        val windowMs = (call.argument<Int>("windowMs") ?: 8_000).coerceIn(1_000, 60_000)
                        result.success(owner() === client && scan(context, windowMs.toLong()))
                    }
                    "pairedDevices" -> result.success(pairedDevices(context))
                    "connect" -> {
                        val device = call.argument<String>("device")
                        val port = call.argument<Int>("port") ?: 0
                        val token = call.argument<ByteArray>("token")
                        val channel = call.argument<Int>("psm") ?: 0
                        val classic = call.argument<Boolean>("classic") ?: false
                        if (device == null || token == null || token.size != TOKEN_BYTES || port <= 0) {
                            result.success(false)
                        } else {
                            connect(context, device, channel, classic, port, token) { ok ->
                                main.post { result.success(ok) }
                            }
                        }
                    }
                    "accept" -> {
                        val id = call.argument<String>("id")
                        val port = call.argument<Int>("port") ?: 0
                        val token = call.argument<ByteArray>("token")
                        val waiting = id?.let { incoming.remove(it) }
                        if (waiting == null || token == null || token.size != TOKEN_BYTES || port <= 0) {
                            waiting?.let { quietly(it.second) }
                            result.success(false)
                        } else {
                            val reply: (Boolean) -> Unit = { ok -> main.post { result.success(ok) } }
                            when (val stream = waiting.second) {
                                is BluetoothSocket -> pipe(waiting.first, stream, port, token, reply)
                                is GattPipe -> pipeGatt(stream, port, token, reply)
                                else -> {
                                    quietly(stream)
                                    reply(false)
                                }
                            }
                        }
                    }
                    "reject" -> {
                        call.argument<String>("id")?.let { id -> incoming.remove(id)?.let { quietly(it.second) } }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: SecurityException) {
                Log.w(TAG, "${call.method}: no permission", error)
                result.success(false)
            } catch (error: Exception) {
                Log.w(TAG, "${call.method} failed", error)
                result.error("bt_link", error.message, null)
            }
        }
    }

    /** The engine whose node gets the streams: the one that started last. */
    private fun owner(): Client? = clients.filter { it.active }.maxByOrNull { it.since }

    private fun send(client: Client?, event: Map<String, Any?>) {
        main.post {
            if (client == null || !client.active || !clients.contains(client)) {
                return@post
            }
            try {
                client.sink?.success(event)
            } catch (error: Exception) {
                Log.w(TAG, "Event for a closed engine dropped", error)
            }
        }
    }

    private fun adapter(context: Context): BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    /** BLE L2CAP channels need Android 10. */
    private fun hasLe(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

    private fun state(context: Context): Map<String, Any> {
        val adapter = adapter(context)
        return mapOf(
            "supported" to (adapter != null),
            "permitted" to ZenNearbyBridge.missingPermissions(context).isEmpty(),
            "enabled" to (adapter?.isEnabled == true),
            "advertBytes" to ADVERT_BYTES,
            "discovery" to hasLe(context),
            "paired" to true,
        )
    }

    /** Stops everything once no engine wants it any more. */
    private fun applyActive(context: Context) {
        if (clients.none { it.active }) {
            shutDown(context)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startServers(context: Context): Boolean {
        val adapter = adapter(context) ?: return false
        if (!adapter.isEnabled || ZenNearbyBridge.missingPermissions(context).isNotEmpty()) {
            return false
        }
        watchBluetoothState(context)
        try {
            if (rfcommServer == null) {
                val server = adapter.listenUsingInsecureRfcommWithServiceRecord("Zen", RFCOMM)
                rfcommServer = server
                acceptLoop(server, l2cap = false)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && hasLe(context) && l2capServer == null) {
                val server = adapter.listenUsingInsecureL2capChannel()
                l2capServer = server
                psm = server.psm
                acceptLoop(server, l2cap = true)
                ensureGattServer(context)
            }
        } catch (error: IOException) {
            Log.w(TAG, "Listening failed", error)
            return rfcommServer != null || l2capServer != null
        }
        return true
    }

    private fun acceptLoop(server: BluetoothServerSocket, l2cap: Boolean) {
        io.execute {
            while (true) {
                val socket = try {
                    server.accept()
                } catch (_: IOException) {
                    break // closed, or Bluetooth went off
                }
                main.post { onAccepted(socket) }
            }
            main.post {
                if (l2cap && l2capServer === server) {
                    l2capServer = null
                    psm = 0
                } else if (!l2cap && rfcommServer === server) {
                    rfcommServer = null
                }
            }
        }
    }

    private fun onAccepted(socket: BluetoothSocket) {
        val owner = owner()
        if (owner == null || incoming.size >= MAX_INCOMING || streams.size >= MAX_STREAMS) {
            quietly(socket)
            return
        }
        val device = socket.remoteDevice?.address ?: ""
        if (incoming.values.count { it.first == device } >= MAX_INCOMING_PER_DEVICE) {
            quietly(socket)
            return
        }
        val id = randomId()
        incoming[id] = device to socket
        main.postDelayed({ incoming.remove(id)?.let { quietly(it.second) } }, INCOMING_WAIT_MS)
        send(owner, mapOf("type" to "incoming", "id" to id))
    }

    /** Pumps [bt] into the bridge's endpoint; [done] tells whether it runs. */
    private fun pipe(device: String, bt: BluetoothSocket, port: Int, token: ByteArray, done: (Boolean) -> Unit) {
        io.execute {
            val loop = Socket()
            try {
                loop.tcpNoDelay = true
                loop.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port), LOOPBACK_WAIT_MS)
                loop.getOutputStream().write(token)
            } catch (error: IOException) {
                Log.w(TAG, "The bridge's endpoint is gone", error)
                quietly(loop)
                quietly(bt)
                done(false)
                return@execute
            }
            val id = randomId()
            val pipe = Pipe(device, bt, loop)
            streams[id] = pipe
            val maxPacket = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) bt.maxTransmitPacketSize else 0
            val finish = {
                pipe.close()
                streams.remove(id)
            }
            io.execute {
                copy(bt.inputStream, loop.getOutputStream(), 0)
                finish()
            }
            io.execute {
                copy(loop.getInputStream(), bt.outputStream, maxPacket)
                finish()
            }
            done(true)
        }
    }

    /** Pumps a GATT stream into the bridge's endpoint, like [pipe]. */
    private fun pipeGatt(gatt: GattPipe, port: Int, token: ByteArray, done: (Boolean) -> Unit) {
        io.execute {
            val loop = Socket()
            try {
                loop.tcpNoDelay = true
                loop.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port), LOOPBACK_WAIT_MS)
                loop.getOutputStream().write(token)
            } catch (error: IOException) {
                Log.w(TAG, "The bridge's endpoint is gone", error)
                quietly(loop)
                gatt.close()
                done(false)
                return@execute
            }
            val id = randomId()
            val pipe = Pipe(gatt.device, gatt, loop)
            streams[id] = pipe
            val finish = {
                pipe.close()
                streams.remove(id)
            }
            io.execute {
                try {
                    val out = loop.getOutputStream()
                    while (true) {
                        val value = gatt.inbound.take()
                        if (value.isEmpty()) break
                        out.write(value)
                        out.flush()
                    }
                } catch (_: Exception) {
                    // Either side closed.
                }
                finish()
            }
            io.execute {
                val buffer = ByteArray(BUFFER)
                try {
                    val input = loop.getInputStream()
                    reading@ while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        var offset = 0
                        while (offset < n) {
                            val length = minOf(maxOf(gatt.mtu - 3, 20), n - offset)
                            if (!gatt.send(buffer.copyOfRange(offset, offset + length))) break@reading
                            offset += length
                        }
                    }
                } catch (_: IOException) {
                    // Either side closed.
                }
                finish()
            }
            done(true)
        }
    }

    private fun copy(from: InputStream, to: OutputStream, maxPacket: Int) {
        val buffer = ByteArray(BUFFER)
        try {
            while (true) {
                val n = from.read(buffer)
                if (n < 0) {
                    return
                }
                var offset = 0
                while (offset < n) {
                    val length = if (maxPacket > 0) minOf(maxPacket, n - offset) else n - offset
                    to.write(buffer, offset, length)
                    offset += length
                }
                to.flush()
            }
        } catch (_: IOException) {
            // Either side closed.
        }
    }

    @SuppressLint("MissingPermission")
    private fun connect(
        context: Context,
        address: String,
        channel: Int,
        classic: Boolean,
        port: Int,
        token: ByteArray,
        done: (Boolean) -> Unit,
    ) {
        val adapter = adapter(context)
        if (adapter == null || !adapter.isEnabled || streams.size >= MAX_STREAMS) {
            done(false)
            return
        }
        if (!classic && !hasLe(context)) {
            done(false)
            return
        }
        val device = (if (classic) null else seen[address])
            ?: if (BluetoothAdapter.checkBluetoothAddress(address)) adapter.getRemoteDevice(address) else null
        if (device == null) {
            done(false)
            return
        }
        if (!classic && channel <= 0) {
            // No L2CAP channel (a Windows computer): a GATT stream.
            connectGattStream(context, device, port, token, done)
            return
        }
        io.execute {
            var socket: BluetoothSocket? = null
            try {
                socket = if (classic) {
                    device.createInsecureRfcommSocketToServiceRecord(RFCOMM)
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    device.createInsecureL2capChannel(channel)
                } else {
                    throw IOException("BLE channels need Android 10")
                }
                if (classic) {
                    // Discovery slows a connection down a lot.
                    adapter.cancelDiscovery()
                }
                socket.connect()
                pipe(address, socket, port, token, done)
            } catch (error: Exception) {
                Log.i(TAG, "No stream to a device nearby: ${error.message}")
                socket?.let { quietly(it) }
                done(false)
            }
        }
    }

    /** Paired phones and computers with no stream open. */
    @SuppressLint("MissingPermission")
    private fun pairedDevices(context: Context): List<String> {
        val adapter = adapter(context) ?: return emptyList()
        if (!adapter.isEnabled || ZenNearbyBridge.missingPermissions(context).isNotEmpty()) {
            return emptyList()
        }
        val open = streams.values.map { it.device }.toSet()
        return adapter.bondedDevices.orEmpty()
            .filter { it.type != BluetoothDevice.DEVICE_TYPE_LE }
            .filter {
                val major = it.bluetoothClass?.majorDeviceClass
                major == BluetoothClass.Device.Major.COMPUTER || major == BluetoothClass.Device.Major.PHONE
            }
            .map { it.address }
            .filter { it !in open }
    }

    // --- BLE: advertising, the GATT service, scanning ---------------------

    @SuppressLint("MissingPermission")
    private fun advertise(context: Context, bytes: ByteArray, windowMs: Int): Boolean {
        if (bytes.size < MIN_ADVERT || bytes.size > MAX_ADVERT) {
            return false
        }
        advert = bytes
        val channel = psm
        if (!hasLe(context) || channel <= 0) {
            return false // nobody could connect
        }
        val adapter = adapter(context) ?: return false
        if (!adapter.isEnabled || ZenNearbyBridge.missingPermissions(context).isNotEmpty()) {
            return false
        }
        val advertiser = adapter.bluetoothLeAdvertiser ?: return false
        stopAdvertising(context)
        ensureGattServer(context)
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(windowMs)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(ParcelUuid(SERVICE))
            .build()
        val response = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
        if (bytes.size <= MAX_RESPONSE_ADVERT) {
            response.addManufacturerData(
                COMPANY_ID,
                MAGIC + byteArrayOf((channel and 0xFF).toByte(), ((channel shr 8) and 0xFF).toByte()) + bytes,
            )
        }
        val callback = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                Log.w(TAG, "Advertising failed: $errorCode")
            }
        }
        advertiser.startAdvertising(settings, data, response.build(), callback)
        advertiseCallback = callback
        return true
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising(context: Context) {
        val callback = advertiseCallback ?: return
        advertiseCallback = null
        try {
            adapter(context)?.bluetoothLeAdvertiser?.stopAdvertising(callback)
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
                override fun onCharacteristicReadRequest(
                    device: BluetoothDevice,
                    requestId: Int,
                    offset: Int,
                    characteristic: BluetoothGattCharacteristic,
                ) {
                    val value = when (characteristic.uuid) {
                        ADVERT -> advert
                        PSM -> psm.let { byteArrayOf((it and 0xFF).toByte(), ((it shr 8) and 0xFF).toByte()) }
                        else -> null
                    }
                    if (value == null || offset > value.size) {
                        server?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                        return
                    }
                    server?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_SUCCESS,
                        offset,
                        value.copyOfRange(offset, value.size),
                    )
                }

                override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                    if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                        gattMtus.remove(device.address)
                        gattServerPipes[device.address]?.close()
                    }
                }

                override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
                    gattMtus[device.address] = mtu
                    gattServerPipes[device.address]?.mtu = mtu
                }

                override fun onDescriptorReadRequest(
                    device: BluetoothDevice,
                    requestId: Int,
                    offset: Int,
                    descriptor: BluetoothGattDescriptor,
                ) {
                    val value = if (gattServerPipes.containsKey(device.address)) {
                        BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    } else {
                        BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                    }
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, value)
                }

                override fun onDescriptorWriteRequest(
                    device: BluetoothDevice,
                    requestId: Int,
                    descriptor: BluetoothGattDescriptor,
                    preparedWrite: Boolean,
                    responseNeeded: Boolean,
                    offset: Int,
                    value: ByteArray?,
                ) {
                    val stream = descriptor.uuid == CCCD && descriptor.characteristic?.uuid == STREAM_OUT
                    if (stream) {
                        if (value != null && value.isNotEmpty() && (value[0].toInt() and 0x01) != 0) {
                            openServerGattPipe(device)
                        } else {
                            gattServerPipes[device.address]?.close()
                        }
                    }
                    if (responseNeeded) {
                        server?.sendResponse(
                            device,
                            requestId,
                            if (stream) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                            0,
                            null,
                        )
                    }
                }

                override fun onCharacteristicWriteRequest(
                    device: BluetoothDevice,
                    requestId: Int,
                    characteristic: BluetoothGattCharacteristic,
                    preparedWrite: Boolean,
                    responseNeeded: Boolean,
                    offset: Int,
                    value: ByteArray?,
                ) {
                    val pipe = if (characteristic.uuid == STREAM_IN && !preparedWrite) {
                        gattServerPipes[device.address]
                    } else {
                        null
                    }
                    // In order: the client waits for this answer before the next.
                    if (value != null) {
                        pipe?.received(value)
                    }
                    if (responseNeeded) {
                        server?.sendResponse(
                            device,
                            requestId,
                            if (pipe != null) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                            0,
                            null,
                        )
                    }
                }

                override fun onNotificationSent(device: BluetoothDevice, status: Int) {
                    notifySent.release()
                }
            },
        )
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        for (uuid in listOf(ADVERT, PSM)) {
            service.addCharacteristic(
                BluetoothGattCharacteristic(
                    uuid,
                    BluetoothGattCharacteristic.PROPERTY_READ,
                    BluetoothGattCharacteristic.PERMISSION_READ,
                ),
            )
        }
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                STREAM_IN,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            ),
        )
        val out = BluetoothGattCharacteristic(
            STREAM_OUT,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        out.addDescriptor(
            BluetoothGattDescriptor(
                CCCD,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            ),
        )
        service.addCharacteristic(out)
        server?.addService(service)
        gattServer = server
    }

    /**
     * A GATT client subscribed to the stream: its pipe exists at once (its
     * first writes may come right after), Dart hears of it on the main
     * thread. Binder threads.
     */
    private fun openServerGattPipe(device: BluetoothDevice) {
        val address = device.address
        if (gattServerPipes[address]?.closed == false) {
            return
        }
        val pipe = GattPipe(address)
        pipe.mtu = gattMtus[address] ?: 23
        pipe.send = { value -> notifyGatt(device, value) }
        pipe.onClose = {
            gattServerPipes.remove(address, pipe)
            // The end, for the client.
            io.execute { notifyGatt(device, ByteArray(0)) }
        }
        gattServerPipes[address] = pipe
        main.post {
            val owner = owner()
            if (owner == null || pipe.closed || incoming.size >= MAX_INCOMING || streams.size >= MAX_STREAMS) {
                pipe.close()
                return@post
            }
            val id = randomId()
            incoming[id] = address to pipe
            main.postDelayed({ incoming.remove(id)?.let { quietly(it.second) } }, INCOMING_WAIT_MS)
            send(owner, mapOf("type" to "incoming", "id" to id))
        }
    }

    /** Notifies [device] of [value] and waits until it went out (one at a time). */
    @SuppressLint("MissingPermission")
    private fun notifyGatt(device: BluetoothDevice, value: ByteArray): Boolean {
        val server = gattServer ?: return false
        val characteristic = server.getService(SERVICE)?.getCharacteristic(STREAM_OUT) ?: return false
        synchronized(notifyLock) {
            notifySent.drainPermits()
            val started = try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    server.notifyCharacteristicChanged(device, characteristic, false, value) ==
                        BluetoothStatusCodes.SUCCESS
                } else {
                    notifyGattLegacy(server, device, characteristic, value)
                }
            } catch (_: Exception) {
                false
            }
            return started && notifySent.tryAcquire(GATT_WRITE_MS, TimeUnit.MILLISECONDS)
        }
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun notifyGattLegacy(
        server: BluetoothGattServer,
        device: BluetoothDevice,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
    ): Boolean {
        characteristic.value = value
        return server.notifyCharacteristicChanged(device, characteristic, false)
    }

    @SuppressLint("MissingPermission")
    private fun writeGatt(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(characteristic, value, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            writeGattLegacy(gatt, characteristic, value)
        }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun writeGattLegacy(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray): Boolean {
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        characteristic.value = value
        return gatt.writeCharacteristic(characteristic)
    }

    @SuppressLint("MissingPermission")
    private fun writeDescriptor(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, value: ByteArray): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
        } else {
            writeDescriptorLegacy(gatt, descriptor, value)
        }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun writeDescriptorLegacy(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, value: ByteArray): Boolean {
        descriptor.value = value
        return gatt.writeDescriptor(descriptor)
    }

    /**
     * Opens a GATT stream to [device] (a Windows computer) and pumps it into
     * the endpoint: connect, a larger MTU, subscribe to …0006, then writes
     * with response to …0005, one at a time.
     */
    @SuppressLint("MissingPermission")
    private fun connectGattStream(
        context: Context,
        device: BluetoothDevice,
        port: Int,
        token: ByteArray,
        done: (Boolean) -> Unit,
    ) {
        val pipe = GattPipe(device.address)
        val connection = AtomicReference<BluetoothGatt?>(null)
        val input = AtomicReference<BluetoothGattCharacteristic?>(null)
        val settled = AtomicBoolean(false)
        val discovering = AtomicBoolean(false)
        val written = Semaphore(0)
        val writeOk = AtomicBoolean(false)
        fun fail() {
            if (settled.compareAndSet(false, true)) {
                pipe.close()
                done(false)
            }
        }
        pipe.onClose = {
            written.release()
            connection.getAndSet(null)?.let { gatt ->
                io.execute {
                    try {
                        gatt.disconnect()
                        gatt.close()
                    } catch (_: Exception) {
                    }
                }
            }
        }
        pipe.send = send@{ value ->
            val gatt = connection.get() ?: return@send false
            val characteristic = input.get() ?: return@send false
            written.drainPermits()
            writeOk.set(false)
            val started = try {
                writeGatt(gatt, characteristic, value)
            } catch (_: Exception) {
                false
            }
            started && written.tryAcquire(GATT_WRITE_MS, TimeUnit.MILLISECONDS) && writeOk.get() && !pipe.closed
        }
        val callback = object : BluetoothGattCallback() {
            fun discover(gatt: BluetoothGatt) {
                if (discovering.compareAndSet(false, true) && !gatt.discoverServices()) {
                    fail()
                }
            }

            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    if (!gatt.requestMtu(GATT_MTU)) {
                        discover(gatt)
                    }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    fail()
                    pipe.close()
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    pipe.mtu = mtu
                }
                discover(gatt)
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                val service = gatt.getService(SERVICE)
                val out = service?.getCharacteristic(STREAM_OUT)
                val into = service?.getCharacteristic(STREAM_IN)
                val subscription = out?.getDescriptor(CCCD)
                if (status != BluetoothGatt.GATT_SUCCESS || out == null || into == null || subscription == null ||
                    !gatt.setCharacteristicNotification(out, true)
                ) {
                    fail()
                    return
                }
                input.set(into)
                if (!writeDescriptor(gatt, subscription, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                    fail()
                }
            }

            override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
                if (descriptor.uuid != CCCD) {
                    return
                }
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    fail()
                } else if (settled.compareAndSet(false, true)) {
                    pipeGatt(pipe, port, token, done)
                }
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) {
                if (characteristic.uuid == STREAM_OUT) {
                    pipe.received(value)
                }
            }

            @Deprecated("Before Android 13")
            override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && characteristic.uuid == STREAM_OUT) {
                    @Suppress("DEPRECATION")
                    val value = characteristic.value?.copyOf() ?: return
                    pipe.received(value)
                }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                if (characteristic.uuid == STREAM_IN) {
                    writeOk.set(status == BluetoothGatt.GATT_SUCCESS)
                    written.release()
                }
            }
        }
        val gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        if (gatt == null) {
            fail()
            return
        }
        connection.set(gatt)
        if (pipe.closed) {
            // Failed before connectGatt returned.
            try {
                gatt.close()
            } catch (_: Exception) {
            }
            return
        }
        main.postDelayed({ fail() }, GATT_CONNECT_MS)
    }

    @SuppressLint("MissingPermission")
    private fun scan(context: Context, windowMs: Long): Boolean {
        if (!hasLe(context)) {
            return false
        }
        val adapter = adapter(context) ?: return false
        if (!adapter.isEnabled || ZenNearbyBridge.missingPermissions(context).isNotEmpty()) {
            return false
        }
        val scanner = adapter.bluetoothLeScanner ?: return false
        stopScan(context)
        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build(),
            ScanFilter.Builder()
                .setManufacturerData(COMPANY_ID, MAGIC, byteArrayOf(0xFF.toByte(), 0xFF.toByte()))
                .build(),
        )
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                main.post { onScanned(context, result) }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                main.post { results.forEach { onScanned(context, it) } }
            }

            override fun onScanFailed(errorCode: Int) {
                Log.w(TAG, "Scan failed: $errorCode")
            }
        }
        scanner.startScan(filters, settings, callback)
        scanCallback = callback
        main.postDelayed(stopScanning, windowMs)
        return true
    }

    @SuppressLint("MissingPermission")
    private fun stopScan(context: Context) {
        main.removeCallbacks(stopScanning)
        val callback = scanCallback ?: return
        scanCallback = null
        try {
            adapter(context)?.bluetoothLeScanner?.stopScan(callback)
        } catch (_: Exception) {
        }
    }

    private fun onScanned(context: Context, result: ScanResult) {
        if (scanCallback == null) {
            return
        }
        val device = result.device ?: return
        val address = device.address
        val now = SystemClock.elapsedRealtime()
        if (now - (seenAt[address] ?: 0L) < SEEN_EVERY_MS) {
            return
        }
        if (seen.size >= MAX_SEEN) {
            seen.clear()
            seenAt.clear()
            gattReadAt.clear()
        }
        seen[address] = device
        val record = result.scanRecord ?: return
        val data = record.getManufacturerSpecificData(COMPANY_ID)
        if (data != null && data.size >= 4 + MIN_ADVERT && data[0] == MAGIC[0] && data[1] == MAGIC[1]) {
            seenAt[address] = now
            val channel = (data[2].toInt() and 0xFF) or ((data[3].toInt() and 0xFF) shl 8)
            reportSeen(address, data.copyOfRange(4, data.size), channel)
            return
        }
        if (record.serviceUuids?.contains(ParcelUuid(SERVICE)) == true) {
            // An iPhone or a Mac: its advert is only on GATT.
            seenAt[address] = now
            readOverGatt(context, device)
        }
    }

    private fun reportSeen(address: String, advertBytes: ByteArray, channel: Int, connectable: Boolean = channel > 0) {
        send(
            owner(),
            mapOf(
                "type" to "seen",
                "device" to address,
                "advert" to hex(advertBytes),
                "psm" to channel,
                "connectable" to connectable,
            ),
        )
    }

    /**
     * Reads the advert and the PSM of a device that shows them on GATT, and
     * whether it takes GATT streams (Windows: PSM 0).
     */
    @SuppressLint("MissingPermission")
    private fun readOverGatt(context: Context, device: BluetoothDevice) {
        val address = device.address
        val now = SystemClock.elapsedRealtime()
        if (gattBusy || now - (gattReadAt[address] ?: 0L) < GATT_REREAD_MS) {
            return
        }
        gattBusy = true
        gattReadAt[address] = now
        var readAdvert: ByteArray? = null
        var finished = false
        var connection: BluetoothGatt? = null
        fun finish(channel: Int, stream: Boolean = false) {
            if (finished) return
            finished = true
            gattBusy = false
            try {
                connection?.disconnect()
                connection?.close()
            } catch (_: Exception) {
            }
            val bytes = readAdvert
            if ((channel > 0 || stream) && bytes != null && bytes.size >= MIN_ADVERT && bytes.size <= MAX_ADVERT) {
                reportSeen(address, bytes, channel, connectable = true)
            }
        }
        fun onRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray?, status: Int) {
            main.post {
                if (status != BluetoothGatt.GATT_SUCCESS || value == null) {
                    finish(0)
                } else if (characteristic.uuid == ADVERT) {
                    readAdvert = value
                    val psmCharacteristic = gatt.getService(SERVICE)?.getCharacteristic(PSM)
                    if (psmCharacteristic == null || !gatt.readCharacteristic(psmCharacteristic)) {
                        finish(0)
                    }
                } else if (characteristic.uuid == PSM && value.size >= 2) {
                    val service = gatt.getService(SERVICE)
                    val stream = service?.getCharacteristic(STREAM_IN) != null &&
                        service?.getCharacteristic(STREAM_OUT) != null
                    finish((value[0].toInt() and 0xFF) or ((value[1].toInt() and 0xFF) shl 8), stream)
                } else {
                    finish(0)
                }
            }
        }
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                main.post {
                    if (newState == BluetoothProfile.STATE_CONNECTED) {
                        if (!gatt.discoverServices()) finish(0)
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                        finish(0)
                    }
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                main.post {
                    val characteristic = gatt.getService(SERVICE)?.getCharacteristic(ADVERT)
                    if (characteristic == null || !gatt.readCharacteristic(characteristic)) {
                        finish(0)
                    }
                }
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) {
                onRead(gatt, characteristic, value, status)
            }

            @Deprecated("Before Android 13")
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    @Suppress("DEPRECATION")
                    onRead(gatt, characteristic, characteristic.value?.copyOf(), status)
                }
            }
        }
        connection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, callback)
        }
        if (connection == null) {
            finish(0)
            return
        }
        main.postDelayed({ finish(0) }, GATT_READ_MS)
    }

    // --- Bluetooth on and off, and stopping --------------------------------

    private fun watchBluetoothState(context: Context) {
        if (stateReceiver != null) {
            return
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(received: Context?, intent: Intent?) {
                if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) {
                    return
                }
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                val on = when (state) {
                    BluetoothAdapter.STATE_ON -> true
                    BluetoothAdapter.STATE_OFF -> false
                    else -> return
                }
                main.post {
                    if (!on) {
                        // The stack dropped the listeners, adverts and scans.
                        closeRadio(context)
                    }
                    for (client in clients.toList()) {
                        send(client, mapOf("type" to "radio", "on" to on))
                    }
                }
            }
        }
        try {
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

    @SuppressLint("MissingPermission")
    private fun closeRadio(context: Context) {
        stopAdvertising(context)
        stopScan(context)
        l2capServer?.let { quietly(it) }
        l2capServer = null
        psm = 0
        rfcommServer?.let { quietly(it) }
        rfcommServer = null
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        gattServer = null
        gattServerPipes.values.forEach { it.close() }
        gattServerPipes.clear()
        gattMtus.clear()
        gattBusy = false
        seen.clear()
        seenAt.clear()
        gattReadAt.clear()
    }

    private fun shutDown(context: Context) {
        closeRadio(context)
        incoming.values.forEach { quietly(it.second) }
        incoming.clear()
        streams.values.forEach { it.close() }
        streams.clear()
        advert = ByteArray(0)
    }

    // --- Helpers --------------------------------------------------------------

    private fun quietly(closeable: Closeable) {
        try {
            closeable.close()
        } catch (_: Exception) {
        }
    }

    private fun randomId(): String {
        val bytes = ByteArray(8)
        random.nextBytes(bytes)
        return hex(bytes)
    }

    private fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            out.append("0123456789abcdef"[v ushr 4]).append("0123456789abcdef"[v and 0x0F])
        }
        return out.toString()
    }

    private fun unhex(text: String?): ByteArray? {
        if (text == null || text.length > 2 * MAX_ADVERT || !HEX.matches(text)) {
            return null
        }
        return ByteArray(text.length / 2) { i -> text.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }
}
