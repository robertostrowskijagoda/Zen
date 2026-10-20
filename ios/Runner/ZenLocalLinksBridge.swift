import CoreBluetooth
import Foundation
import MultipeerConnectivity
import Security

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// Links with friends nearby without a network (§5.1 item 6) on iPhone,
/// iPad and Mac; one file for both apps (the Mac project refers to this
/// one). Dart decides whom to link with (native_stream_local_link.dart);
/// this file drives the radios and pumps each stream into the endpoint the
/// Go bridge gave Dart: it connects to 127.0.0.1:port, writes the 16-byte
/// token, then copies both ways until either side closes. The bridge's
/// handshake proves the pair and refuses everyone else.
///
///  - `zen/bt_link`: CoreBluetooth. This device advertises the Zen link
///    service UUID (Apple lets apps show nothing else) and serves its
///    advert and its L2CAP PSM on GATT; it scans for every device while Zen
///    is open and reads others' adverts from their manufacturer data
///    (Android, Linux: "ZL", the PSM, the advert) or over GATT (Apple).
///    Streams are L2CAP channels without encryption (the bridge encrypts),
///    the same as Android's insecure ones.
///  - `zen/multipeer`: Multipeer Connectivity between Apple devices
///    (Bluetooth and peer-to-peer Wi-Fi): the advert goes in the discovery
///    info, an invitation carries the inviter's, and each side opens one
///    stream to the other.
///
/// iOS stops both when Zen leaves the screen; Dart stops them then anyway.
enum ZenLocalLinksBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    BluetoothLinkRadio.shared.attach(messenger)
    MultipeerLinkRadio.shared.attach(messenger)
  }
}

// MARK: - Shared

private let tokenLength = 16
private let minAdvertLength = 7 + 8
private let maxAdvertLength = 7 + 1024

private func hexString(_ data: Data) -> String {
  return data.map { String(format: "%02x", $0) }.joined()
}

private func hexData(_ text: String?) -> Data? {
  guard let text = text, text.count % 2 == 0, text.count <= 2 * maxAdvertLength else {
    return nil
  }
  var out = Data(capacity: text.count / 2)
  var index = text.startIndex
  while index < text.endIndex {
    let next = text.index(index, offsetBy: 2)
    guard let byte = UInt8(text[index..<next], radix: 16) else {
      return nil
    }
    out.append(byte)
    index = next
  }
  return out
}

private func randomId() -> String {
  var bytes = [UInt8](repeating: 0, count: 8)
  if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
    for i in bytes.indices {
      bytes[i] = UInt8.random(in: 0...255)
    }
  }
  return hexString(Data(bytes))
}

/// The endpoint Dart passed: a loopback port and the token.
private struct Endpoint {
  let port: Int
  let token: Data

  init?(_ arguments: [String: Any]?) {
    guard let port = arguments?["port"] as? Int, port > 0, port <= 65535,
      let token = (arguments?["token"] as? FlutterStandardTypedData)?.data,
      token.count == tokenLength
    else {
      return nil
    }
    self.port = port
    self.token = token
  }
}

/// Events for Dart on `<name>/events`.
private final class EventSender: NSObject, FlutterStreamHandler {
  var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func send(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.sink?(event)
    }
  }
}

/// Copies between a stream pair (an L2CAP channel's, or two Multipeer
/// streams) and the bridge's loopback endpoint, on a thread of its own,
/// until either side ends. The token goes to the endpoint first.
final class StreamPump: NSObject, StreamDelegate {
  private static let bufferLimit = 256 * 1024
  private static let chunk = 16 * 1024

  private let remoteIn: InputStream
  private let remoteOut: OutputStream
  private let loopIn: InputStream
  private let loopOut: OutputStream
  private var toLoop: Data
  private var toRemote = Data()
  private let lock = NSLock()
  private var stopped = false
  private var onEnd: (() -> Void)?
  /// Kept alive as long as the streams (an L2CAP channel).
  private let owner: AnyObject?

  init?(input: InputStream, output: OutputStream, port: Int, token: Data, owner: AnyObject?) {
    var loopInput: InputStream?
    var loopOutput: OutputStream?
    Stream.getStreamsToHost(
      withName: "127.0.0.1", port: port, inputStream: &loopInput, outputStream: &loopOutput)
    guard let loopInput = loopInput, let loopOutput = loopOutput else {
      return nil
    }
    remoteIn = input
    remoteOut = output
    loopIn = loopInput
    loopOut = loopOutput
    toLoop = token
    self.owner = owner
    super.init()
  }

  private var streams: [Stream] { [remoteIn, remoteOut, loopIn, loopOut] }

  /// Starts pumping; [onEnd] runs on the main queue once it has ended.
  func start(onEnd: @escaping () -> Void) {
    self.onEnd = onEnd
    let thread = Thread { [self] in self.run() }
    thread.name = "zen.link.pump"
    thread.start()
  }

  /// Ends it (from any thread).
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  private func run() {
    let loop = RunLoop.current
    for stream in streams {
      stream.delegate = self
      stream.schedule(in: loop, forMode: .default)
      stream.open()
    }
    while !isStopped {
      _ = loop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
    }
    for stream in streams {
      stream.close()
      stream.remove(from: loop, forMode: .default)
      stream.delegate = nil
    }
    let end = onEnd
    onEnd = nil
    DispatchQueue.main.async {
      end?()
    }
  }

  func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    switch eventCode {
    case .hasBytesAvailable, .hasSpaceAvailable:
      pump()
    case .errorOccurred, .endEncountered:
      stop()
    default:
      break
    }
  }

  private func pump() {
    // Reads while there is room, writes while there is space.
    var moved = true
    while moved && !isStopped {
      moved = false
      moved = read(from: remoteIn, into: &toLoop) || moved
      moved = read(from: loopIn, into: &toRemote) || moved
      moved = write(&toLoop, to: loopOut) || moved
      moved = write(&toRemote, to: remoteOut) || moved
    }
  }

  private func read(from input: InputStream, into buffer: inout Data) -> Bool {
    guard input.hasBytesAvailable, buffer.count < StreamPump.bufferLimit else {
      return false
    }
    var bytes = [UInt8](repeating: 0, count: StreamPump.chunk)
    let n = input.read(&bytes, maxLength: bytes.count)
    if n < 0 {
      stop()
      return false
    }
    if n == 0 {
      if input.streamStatus == .atEnd {
        stop()
      }
      return false
    }
    buffer.append(contentsOf: bytes[0..<n])
    return true
  }

  private func write(_ buffer: inout Data, to output: OutputStream) -> Bool {
    guard !buffer.isEmpty, output.hasSpaceAvailable else {
      return false
    }
    let n = buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
        return 0
      }
      return output.write(base, maxLength: raw.count)
    }
    if n < 0 {
      stop()
      return false
    }
    if n == 0 {
      return false
    }
    buffer.removeFirst(n)
    return true
  }
}

// MARK: - Bluetooth (CoreBluetooth)

final class BluetoothLinkRadio: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate,
  CBPeripheralDelegate
{
  static let shared = BluetoothLinkRadio()

  private static let service = CBUUID(string: "5A454E00-6C69-6E6B-0000-000000000001")
  private static let advertCharacteristic = CBUUID(string: "5A454E00-6C69-6E6B-0000-000000000002")
  private static let psmCharacteristic = CBUUID(string: "5A454E00-6C69-6E6B-0000-000000000003")
  private static let magic: [UInt8] = [0x5A, 0x4C]
  private static let incomingWait: TimeInterval = 15
  private static let connectWait: TimeInterval = 20
  private static let gattReadWait: TimeInterval = 10
  private static let gattRereadAfter: TimeInterval = 120
  private static let seenEvery: TimeInterval = 3
  private static let maxSeen = 512
  private static let maxIncoming = 8
  private static let maxStreams = 16

  private let events = EventSender()
  private var central: CBCentralManager?
  private var peripheralManager: CBPeripheralManager?
  private var running = false
  private var psm: CBL2CAPPSM = 0
  private var publishing = false
  private var advert = Data()
  private var serviceAdded = false
  private var advertiseTimer: Timer?
  private var scanTimer: Timer?

  private var seen: [UUID: CBPeripheral] = [:]
  private var seenAt: [UUID: Date] = [:]
  private var gattReadAt: [UUID: Date] = [:]

  /// The one GATT read going on.
  private var reading: (peripheral: CBPeripheral, advert: Data?, timer: Timer)?

  private struct Dial {
    let psm: CBL2CAPPSM
    let endpoint: Endpoint
    let result: FlutterResult
    let timer: Timer
  }

  private var dials: [UUID: Dial] = [:]
  private var incoming: [String: CBL2CAPChannel] = [:]
  private var pumps: [String: StreamPump] = [:]
  /// Peripherals a stream was opened to, by pump.
  private var pumpPeripherals: [String: CBPeripheral] = [:]

  func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zen/bt_link", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result) ?? result(nil)
    }
    FlutterEventChannel(name: "zen/bt_link/events", binaryMessenger: messenger)
      .setStreamHandler(events)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "state":
      result(state())
    case "requestPermissions":
      // Making the managers shows the system's question the first time.
      ensureManagers()
      result(CBManager.authorization == .allowedAlways)
    case "start":
      result(start())
    case "stop":
      stop()
      result(nil)
    case "advertise":
      let window = (arguments?["windowMs"] as? Int ?? 20000)
      result(advertise(hexData(arguments?["advert"] as? String), window: window))
    case "scan":
      result(scan(window: arguments?["windowMs"] as? Int ?? 8000))
    case "pairedDevices":
      result([String]())
    case "connect":
      guard let device = arguments?["device"] as? String,
        let endpoint = Endpoint(arguments),
        let psm = arguments?["psm"] as? Int, psm > 0, psm <= 0xFFFF
      else {
        result(false)
        return
      }
      connect(device, psm: CBL2CAPPSM(psm), endpoint: endpoint, result: result)
    case "accept":
      guard let id = arguments?["id"] as? String, let channel = incoming.removeValue(forKey: id)
      else {
        result(false)
        return
      }
      guard let endpoint = Endpoint(arguments) else {
        close(channel)
        result(false)
        return
      }
      result(startPump(channel, endpoint: endpoint, peripheral: nil))
    case "reject":
      if let id = arguments?["id"] as? String, let channel = incoming.removeValue(forKey: id) {
        close(channel)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func state() -> [String: Any] {
    let authorization = CBManager.authorization
    if authorization == .allowedAlways {
      ensureManagers()
    }
    let unsupported = central?.state == .unsupported
    return [
      "supported": !unsupported && authorization != .restricted,
      "permitted": authorization == .allowedAlways,
      "enabled": central?.state == .poweredOn && peripheralManager?.state == .poweredOn,
      // On GATT only: a long read, well under the 512-byte attribute limit.
      "advertBytes": 64,
      "discovery": true,
      "paired": false,
    ]
  }

  private func ensureManagers() {
    if central == nil {
      central = CBCentralManager(delegate: self, queue: nil)
    }
    if peripheralManager == nil {
      peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }
  }

  private func start() -> Bool {
    guard CBManager.authorization == .allowedAlways else {
      return false
    }
    ensureManagers()
    running = true
    guard central?.state == .poweredOn, let manager = peripheralManager,
      manager.state == .poweredOn
    else {
      return false
    }
    publish(manager)
    return true
  }

  /// The L2CAP channel and the GATT service, once.
  private func publish(_ manager: CBPeripheralManager) {
    if psm == 0 && !publishing {
      publishing = true
      manager.publishL2CAPChannel(withEncryption: false)
    }
    if !serviceAdded {
      let service = CBMutableService(type: BluetoothLinkRadio.service, primary: true)
      service.characteristics = [
        CBMutableCharacteristic(
          type: BluetoothLinkRadio.advertCharacteristic, properties: [.read], value: nil,
          permissions: [.readable]),
        CBMutableCharacteristic(
          type: BluetoothLinkRadio.psmCharacteristic, properties: [.read], value: nil,
          permissions: [.readable]),
      ]
      manager.add(service)
      serviceAdded = true
    }
  }

  private func stop() {
    running = false
    stopAdvertising()
    stopScan()
    if let manager = peripheralManager {
      if psm != 0 {
        manager.unpublishL2CAPChannel(psm)
      }
      manager.removeAllServices()
    }
    psm = 0
    publishing = false
    serviceAdded = false
    advert = Data()
    for (_, channel) in incoming {
      close(channel)
    }
    incoming.removeAll()
    for (_, pump) in pumps {
      pump.stop()
    }
    for (peripheral, dial) in dials {
      dial.timer.invalidate()
      dial.result(false)
      if let known = seen[peripheral] {
        central?.cancelPeripheralConnection(known)
      }
    }
    dials.removeAll()
    endReading(psm: nil)
    seen.removeAll()
    seenAt.removeAll()
    gattReadAt.removeAll()
  }

  private func close(_ channel: CBL2CAPChannel) {
    channel.inputStream.close()
    channel.outputStream.close()
  }

  // Advertising

  private func advertise(_ bytes: Data?, window: Int) -> Bool {
    guard let bytes = bytes, bytes.count >= minAdvertLength, bytes.count <= maxAdvertLength else {
      return false
    }
    advert = bytes
    guard running, psm != 0, let manager = peripheralManager, manager.state == .poweredOn else {
      return false
    }
    stopAdvertising()
    manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [BluetoothLinkRadio.service]])
    let seconds = TimeInterval(min(max(window, 1000), 180_000)) / 1000
    advertiseTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
      [weak self] _ in
      self?.stopAdvertising()
    }
    return true
  }

  private func stopAdvertising() {
    advertiseTimer?.invalidate()
    advertiseTimer = nil
    if peripheralManager?.isAdvertising == true {
      peripheralManager?.stopAdvertising()
    }
  }

  // Scanning

  private func scan(window: Int) -> Bool {
    guard running, let central = central, central.state == .poweredOn else {
      return false
    }
    stopScan()
    // Every device: Linux shows only manufacturer data.
    central.scanForPeripherals(
      withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    let seconds = TimeInterval(min(max(window, 1000), 60_000)) / 1000
    scanTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      self?.stopScan()
    }
    return true
  }

  private func stopScan() {
    scanTimer?.invalidate()
    scanTimer = nil
    if central?.isScanning == true {
      central?.stopScan()
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    guard running else {
      return
    }
    let id = peripheral.identifier
    let now = Date()
    if let last = seenAt[id], now.timeIntervalSince(last) < BluetoothLinkRadio.seenEvery {
      return
    }
    if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
      // Company 0xFFFF, "ZL", the PSM, the advert.
      let bytes = [UInt8](data)
      if bytes.count >= 4 + 2 + minAdvertLength, bytes[0] == 0xFF, bytes[1] == 0xFF,
        bytes[2] == BluetoothLinkRadio.magic[0], bytes[3] == BluetoothLinkRadio.magic[1]
      {
        remember(peripheral, at: now)
        let channel = Int(bytes[4]) | (Int(bytes[5]) << 8)
        reportSeen(peripheral, advert: Data(bytes[6...]), psm: channel)
        return
      }
    }
    if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
      services.contains(BluetoothLinkRadio.service)
    {
      // An Apple device: its advert is only on GATT.
      remember(peripheral, at: now)
      readOverGatt(peripheral, now: now)
    }
  }

  private func remember(_ peripheral: CBPeripheral, at now: Date) {
    if seen.count >= BluetoothLinkRadio.maxSeen && seen[peripheral.identifier] == nil {
      seen = seen.filter { dials[$0.key] != nil || reading?.peripheral.identifier == $0.key }
      seenAt.removeAll()
      gattReadAt.removeAll()
    }
    seen[peripheral.identifier] = peripheral
    seenAt[peripheral.identifier] = now
  }

  private func reportSeen(_ peripheral: CBPeripheral, advert: Data, psm: Int) {
    events.send([
      "type": "seen",
      "device": peripheral.identifier.uuidString,
      "advert": hexString(advert),
      "psm": psm,
      "connectable": psm > 0,
    ])
  }

  private func readOverGatt(_ peripheral: CBPeripheral, now: Date) {
    let id = peripheral.identifier
    if reading != nil || dials[id] != nil {
      return
    }
    if let last = gattReadAt[id], now.timeIntervalSince(last) < BluetoothLinkRadio.gattRereadAfter {
      return
    }
    gattReadAt[id] = now
    let timer = Timer.scheduledTimer(
      withTimeInterval: BluetoothLinkRadio.gattReadWait, repeats: false
    ) { [weak self] _ in
      self?.endReading(psm: nil)
    }
    reading = (peripheral, nil, timer)
    peripheral.delegate = self
    central?.connect(peripheral, options: nil)
  }

  /// Ends the GATT read; with the PSM read, tells Dart what it found.
  private func endReading(psm psmValue: Int?) {
    guard let current = reading else {
      return
    }
    reading = nil
    current.timer.invalidate()
    central?.cancelPeripheralConnection(current.peripheral)
    if let psmValue = psmValue, psmValue > 0, let bytes = current.advert,
      bytes.count >= minAdvertLength, bytes.count <= maxAdvertLength
    {
      reportSeen(current.peripheral, advert: bytes, psm: psmValue)
    }
  }

  // Connecting

  private func connect(
    _ device: String, psm: CBL2CAPPSM, endpoint: Endpoint, result: @escaping FlutterResult
  ) {
    guard running, pumps.count < BluetoothLinkRadio.maxStreams, let central = central,
      central.state == .poweredOn, let id = UUID(uuidString: device)
    else {
      result(false)
      return
    }
    guard
      let peripheral = seen[id]
        ?? central.retrievePeripherals(withIdentifiers: [id]).first,
      dials[id] == nil, reading?.peripheral.identifier != id
    else {
      result(false)
      return
    }
    seen[id] = peripheral
    let timer = Timer.scheduledTimer(
      withTimeInterval: BluetoothLinkRadio.connectWait, repeats: false
    ) { [weak self] _ in
      self?.failDial(id)
    }
    dials[id] = Dial(psm: psm, endpoint: endpoint, result: result, timer: timer)
    peripheral.delegate = self
    if peripheral.state == .connected {
      peripheral.openL2CAPChannel(psm)
    } else {
      central.connect(peripheral, options: nil)
    }
  }

  private func failDial(_ id: UUID) {
    guard let dial = dials.removeValue(forKey: id) else {
      return
    }
    dial.timer.invalidate()
    dial.result(false)
    if let peripheral = seen[id] {
      central?.cancelPeripheralConnection(peripheral)
    }
  }

  private func startPump(_ channel: CBL2CAPChannel, endpoint: Endpoint, peripheral: CBPeripheral?)
    -> Bool
  {
    guard
      let pump = StreamPump(
        input: channel.inputStream, output: channel.outputStream, port: endpoint.port,
        token: endpoint.token, owner: channel)
    else {
      close(channel)
      return false
    }
    let id = randomId()
    pumps[id] = pump
    if let peripheral = peripheral {
      pumpPeripherals[id] = peripheral
    }
    pump.start { [weak self] in
      guard let self = self else {
        return
      }
      self.pumps.removeValue(forKey: id)
      if let peripheral = self.pumpPeripherals.removeValue(forKey: id) {
        self.central?.cancelPeripheralConnection(peripheral)
      }
    }
    return true
  }

  // CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state != .poweredOn {
      for id in Array(dials.keys) {
        failDial(id)
      }
      endReading(psm: nil)
      seen.removeAll()
    }
    events.send(["type": "radio", "on": central.state == .poweredOn])
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    let id = peripheral.identifier
    if let dial = dials[id] {
      peripheral.openL2CAPChannel(dial.psm)
    } else if reading?.peripheral.identifier == id {
      peripheral.discoverServices([BluetoothLinkRadio.service])
    } else {
      central.cancelPeripheralConnection(peripheral)
    }
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    lost(peripheral)
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    lost(peripheral)
  }

  private func lost(_ peripheral: CBPeripheral) {
    let id = peripheral.identifier
    if dials[id] != nil {
      failDial(id)
    }
    if reading?.peripheral.identifier == id {
      endReading(psm: nil)
    }
  }

  // CBPeripheralDelegate (this device as the central)

  func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
    let id = peripheral.identifier
    guard let dial = dials.removeValue(forKey: id) else {
      if let channel = channel {
        close(channel)
      }
      return
    }
    dial.timer.invalidate()
    guard let channel = channel, error == nil else {
      dial.result(false)
      central?.cancelPeripheralConnection(peripheral)
      return
    }
    let started = startPump(channel, endpoint: dial.endpoint, peripheral: peripheral)
    if !started {
      central?.cancelPeripheralConnection(peripheral)
    }
    dial.result(started)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard reading?.peripheral.identifier == peripheral.identifier,
      let service = peripheral.services?.first(where: { $0.uuid == BluetoothLinkRadio.service })
    else {
      endReading(psm: nil)
      return
    }
    peripheral.discoverCharacteristics(
      [BluetoothLinkRadio.advertCharacteristic, BluetoothLinkRadio.psmCharacteristic],
      for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    guard reading?.peripheral.identifier == peripheral.identifier,
      let characteristic = service.characteristics?.first(where: {
        $0.uuid == BluetoothLinkRadio.advertCharacteristic
      })
    else {
      endReading(psm: nil)
      return
    }
    peripheral.readValue(for: characteristic)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard let current = reading, current.peripheral.identifier == peripheral.identifier else {
      return
    }
    guard error == nil, let value = characteristic.value else {
      endReading(psm: nil)
      return
    }
    if characteristic.uuid == BluetoothLinkRadio.advertCharacteristic {
      reading = (current.peripheral, value, current.timer)
      guard
        let psmCharacteristic = characteristic.service?.characteristics?.first(where: {
          $0.uuid == BluetoothLinkRadio.psmCharacteristic
        })
      else {
        endReading(psm: nil)
        return
      }
      peripheral.readValue(for: psmCharacteristic)
    } else if characteristic.uuid == BluetoothLinkRadio.psmCharacteristic, value.count >= 2 {
      let bytes = [UInt8](value)
      endReading(psm: Int(bytes[0]) | (Int(bytes[1]) << 8))
    } else {
      endReading(psm: nil)
    }
  }

  // CBPeripheralManagerDelegate (this device as the peripheral)

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    if peripheral.state == .poweredOn {
      if running {
        publish(peripheral)
      }
    } else {
      // The stack forgot the channel, the service and the advertising.
      psm = 0
      publishing = false
      serviceAdded = false
      advertiseTimer?.invalidate()
      advertiseTimer = nil
    }
    events.send(["type": "radio", "on": peripheral.state == .poweredOn])
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?
  ) {
    publishing = false
    if error == nil {
      psm = PSM
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, didUnpublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?
  ) {
    if psm == PSM {
      psm = 0
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?
  ) {
    guard let channel = channel, error == nil else {
      return
    }
    guard running, incoming.count < BluetoothLinkRadio.maxIncoming,
      pumps.count < BluetoothLinkRadio.maxStreams
    else {
      close(channel)
      return
    }
    let id = randomId()
    incoming[id] = channel
    DispatchQueue.main.asyncAfter(deadline: .now() + BluetoothLinkRadio.incomingWait) {
      [weak self] in
      if let waiting = self?.incoming.removeValue(forKey: id) {
        self?.close(waiting)
      }
    }
    events.send(["type": "incoming", "id": id])
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    let value: Data
    switch request.characteristic.uuid {
    case BluetoothLinkRadio.advertCharacteristic:
      value = advert
    case BluetoothLinkRadio.psmCharacteristic:
      value = Data([UInt8(psm & 0xFF), UInt8((psm >> 8) & 0xFF)])
    default:
      peripheral.respond(to: request, withResult: .attributeNotFound)
      return
    }
    guard request.offset <= value.count else {
      peripheral.respond(to: request, withResult: .invalidOffset)
      return
    }
    request.value = value.subdata(in: request.offset..<value.count)
    peripheral.respond(to: request, withResult: .success)
  }
}

// MARK: - Multipeer Connectivity (Apple devices)

final class MultipeerLinkRadio: NSObject, MCNearbyServiceAdvertiserDelegate,
  MCNearbyServiceBrowserDelegate, MCSessionDelegate
{
  static let shared = MultipeerLinkRadio()

  /// Also in Info.plist (NSBonjourServices: _zen-link._tcp and ._udp).
  private static let serviceType = "zen-link"
  private static let streamName = "zen"
  private static let incomingWait: TimeInterval = 15
  private static let connectWait: TimeInterval = 30
  private static let maxLinks = 16

  private let events = EventSender()
  /// A random name for this run: nothing about the person or the device.
  private let me = MCPeerID(displayName: randomId())
  private var running = false
  private var advertiser: MCNearbyServiceAdvertiser?
  private var browser: MCNearbyServiceBrowser?
  private var advertiseTimer: Timer?
  private var browseTimer: Timer?
  private var peers: [String: MCPeerID] = [:]

  private final class Link {
    let peer: MCPeerID
    let session: MCSession
    let endpoint: Endpoint
    var result: FlutterResult?
    var input: InputStream?
    var output: OutputStream?
    var pump: StreamPump?
    var timer: Timer?

    init(peer: MCPeerID, session: MCSession, endpoint: Endpoint, result: FlutterResult?) {
      self.peer = peer
      self.session = session
      self.endpoint = endpoint
      self.result = result
    }
  }

  private var links: [String: Link] = [:]
  private var invitations: [String: (peer: MCPeerID, handler: (Bool, MCSession?) -> Void)] = [:]

  func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zen/multipeer", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result) ?? result(nil)
    }
    FlutterEventChannel(name: "zen/multipeer/events", binaryMessenger: messenger)
      .setStreamHandler(events)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "state":
      result([
        "supported": true,
        "permitted": true,
        "enabled": true,
        "advertBytes": 64,
        "discovery": true,
        "paired": false,
      ])
    case "requestPermissions":
      result(true)
    case "start":
      running = true
      result(true)
    case "stop":
      stop()
      result(nil)
    case "advertise":
      result(advertise(arguments?["advert"] as? String, window: arguments?["windowMs"] as? Int))
    case "scan":
      result(browse(window: arguments?["windowMs"] as? Int))
    case "pairedDevices":
      result([String]())
    case "connect":
      guard let device = arguments?["device"] as? String, let endpoint = Endpoint(arguments)
      else {
        result(false)
        return
      }
      invite(device, endpoint: endpoint, advert: hexData(arguments?["advert"] as? String), result: result)
    case "accept":
      guard let id = arguments?["id"] as? String, let invitation = invitations.removeValue(forKey: id)
      else {
        result(false)
        return
      }
      guard let endpoint = Endpoint(arguments), running, links.count < MultipeerLinkRadio.maxLinks
      else {
        invitation.handler(false, nil)
        result(false)
        return
      }
      let session = newSession()
      let link = Link(peer: invitation.peer, session: session, endpoint: endpoint, result: nil)
      replaceLink(invitation.peer.displayName, with: link)
      invitation.handler(true, session)
      result(true)
    case "reject":
      if let id = arguments?["id"] as? String, let invitation = invitations.removeValue(forKey: id) {
        invitation.handler(false, nil)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func newSession() -> MCSession {
    // The bridge encrypts the stream itself.
    let session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .none)
    session.delegate = self
    return session
  }

  private func replaceLink(_ key: String, with link: Link) {
    if let old = links[key] {
      end(old, key: key)
    }
    links[key] = link
    link.timer = Timer.scheduledTimer(
      withTimeInterval: MultipeerLinkRadio.connectWait, repeats: false
    ) { [weak self] _ in
      guard let self = self, let current = self.links[key], current === link,
        current.pump == nil
      else {
        return
      }
      self.end(current, key: key)
    }
  }

  private func stop() {
    running = false
    stopAdvertising()
    stopBrowsing()
    for (_, invitation) in invitations {
      invitation.handler(false, nil)
    }
    invitations.removeAll()
    for (key, link) in links {
      end(link, key: key)
    }
    links.removeAll()
    peers.removeAll()
    advertiser = nil
    browser = nil
  }

  private func advertise(_ advert: String?, window: Int?) -> Bool {
    guard running, let advert = advert, hexData(advert) != nil else {
      return false
    }
    stopAdvertising()
    let advertiser = MCNearbyServiceAdvertiser(
      peer: me, discoveryInfo: ["a": advert], serviceType: MultipeerLinkRadio.serviceType)
    advertiser.delegate = self
    advertiser.startAdvertisingPeer()
    self.advertiser = advertiser
    let seconds = TimeInterval(min(max(window ?? 20000, 1000), 180_000)) / 1000
    advertiseTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
      [weak self] _ in
      self?.stopAdvertising()
    }
    return true
  }

  private func stopAdvertising() {
    advertiseTimer?.invalidate()
    advertiseTimer = nil
    advertiser?.stopAdvertisingPeer()
  }

  private func browse(window: Int?) -> Bool {
    guard running else {
      return false
    }
    // Kept between windows: invitations go through the browser that found
    // the peer.
    let browser =
      self.browser
      ?? MCNearbyServiceBrowser(peer: me, serviceType: MultipeerLinkRadio.serviceType)
    browser.delegate = self
    self.browser = browser
    browseTimer?.invalidate()
    browser.startBrowsingForPeers()
    let seconds = TimeInterval(min(max(window ?? 8000, 1000), 60_000)) / 1000
    browseTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
      [weak self] _ in
      self?.stopBrowsing()
    }
    return true
  }

  private func stopBrowsing() {
    browseTimer?.invalidate()
    browseTimer = nil
    browser?.stopBrowsingForPeers()
  }

  private func invite(
    _ device: String, endpoint: Endpoint, advert: Data?, result: @escaping FlutterResult
  ) {
    guard running, let browser = browser, let peer = peers[device],
      links.count < MultipeerLinkRadio.maxLinks
    else {
      result(false)
      return
    }
    let session = newSession()
    let link = Link(peer: peer, session: session, endpoint: endpoint, result: result)
    replaceLink(device, with: link)
    browser.invitePeer(
      peer, to: session, withContext: advert, timeout: MultipeerLinkRadio.connectWait)
  }

  /// Both streams are there: pump them.
  private func startPumpIfReady(_ link: Link, key: String) {
    guard link.pump == nil, let input = link.input, let output = link.output else {
      return
    }
    guard
      let pump = StreamPump(
        input: input, output: output, port: link.endpoint.port, token: link.endpoint.token,
        owner: link.session)
    else {
      end(link, key: key)
      return
    }
    link.pump = pump
    link.timer?.invalidate()
    link.result?(true)
    link.result = nil
    pump.start { [weak self] in
      guard let self = self, let current = self.links[key], current === link else {
        return
      }
      self.end(link, key: key)
    }
  }

  private func end(_ link: Link, key: String) {
    link.timer?.invalidate()
    link.pump?.stop()
    link.result?(false)
    link.result = nil
    link.session.disconnect()
    if links[key] === link {
      links.removeValue(forKey: key)
    }
  }

  // MCNearbyServiceAdvertiserDelegate (background queue)

  func advertiser(
    _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void
  ) {
    DispatchQueue.main.async { [self] in
      guard running, let context = context, context.count >= minAdvertLength,
        invitations.count < 8
      else {
        invitationHandler(false, nil)
        return
      }
      let id = randomId()
      invitations[id] = (peerID, invitationHandler)
      DispatchQueue.main.asyncAfter(deadline: .now() + MultipeerLinkRadio.incomingWait) {
        [weak self] in
        self?.invitations.removeValue(forKey: id)?.handler(false, nil)
      }
      events.send(["type": "incoming", "id": id, "advert": hexString(context)])
    }
  }

  func advertiser(
    _ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error
  ) {
    NSLog("Zen: Multipeer advertising failed")
  }

  // MCNearbyServiceBrowserDelegate (background queue)

  func browser(
    _ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
    withDiscoveryInfo info: [String: String]?
  ) {
    DispatchQueue.main.async { [self] in
      guard running, peerID != me, let advert = info?["a"], hexData(advert) != nil else {
        return
      }
      peers[peerID.displayName] = peerID
      events.send(["type": "seen", "device": peerID.displayName, "advert": advert])
    }
  }

  func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    DispatchQueue.main.async { [self] in
      if peers[peerID.displayName] == peerID {
        peers.removeValue(forKey: peerID.displayName)
      }
    }
  }

  func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
    NSLog("Zen: Multipeer browsing failed")
  }

  // MCSessionDelegate (background queue)

  private func linkKey(for session: MCSession) -> String? {
    return links.first(where: { $0.value.session === session })?.key
  }

  func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    DispatchQueue.main.async { [self] in
      guard let key = linkKey(for: session), let link = links[key], link.peer == peerID else {
        return
      }
      switch state {
      case .connected:
        if link.output == nil {
          do {
            link.output = try session.startStream(
              withName: MultipeerLinkRadio.streamName, toPeer: peerID)
          } catch {
            end(link, key: key)
            return
          }
        }
        startPumpIfReady(link, key: key)
      case .notConnected:
        end(link, key: key)
      default:
        break
      }
    }
  }

  func session(
    _ session: MCSession, didReceive stream: InputStream, withName streamName: String,
    fromPeer peerID: MCPeerID
  ) {
    DispatchQueue.main.async { [self] in
      guard streamName == MultipeerLinkRadio.streamName, let key = linkKey(for: session),
        let link = links[key], link.peer == peerID, link.input == nil
      else {
        stream.close()
        return
      }
      link.input = stream
      startPumpIfReady(link, key: key)
    }
  }

  func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}

  func session(
    _ session: MCSession, didStartReceivingResourceWithName resourceName: String,
    fromPeer peerID: MCPeerID, with progress: Progress
  ) {}

  func session(
    _ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
    fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?
  ) {}
}
