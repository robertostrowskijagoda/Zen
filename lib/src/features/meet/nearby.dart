import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby_crypto.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

export 'package:zen/src/features/meet/nearby_crypto.dart';

/// Mesh payload of a conversation started nearby.
const String kNearbyMessageType = 'nearby_msg';

/// Hello without any address: the pseudonym, the message, the sender's
/// token and the id (`kh`, [nearbyPieceId]) of a one-time hybrid
/// post-quantum public key (ML-KEM-768 + X25519, hybrid_kem.dart), which
/// goes before it in parts ([nearbyParts], `h`). Nobody learns an address
/// until the other person answers.
const int kNearbyHelloVersion = 9;

/// The answer to a [kNearbyHelloVersion] hello, over Bluetooth: the
/// answering person's mesh address, pseudonym and message, sealed with a
/// key encapsulated to the hello's one-time key (only that phone can open
/// it, also later with a quantum computer). The ciphertext goes before it
/// in parts (`r`), named by `ch`.
const int kNearbyReplyVersion = 10;

/// Longest first message and longest answer over Bluetooth (a write holds
/// about 1 KB).
const int kNearbyHelloMaxLength = 300;
const int kNearbyReplyMaxLength = 200;

String _hex(List<int> b) => nearbyHex(b);

List<String> get _adjectives => <String>[
  t('Zielony'),
  t('Rudy'),
  t('Cichy'),
  t('Szybki'),
  t('Mądry'),
  t('Wesoły'),
  t('Śmiały'),
  t('Złoty'),
  t('Srebrny'),
  t('Nocny'),
  t('Leśny'),
  t('Spokojny'),
  t('Dziki'),
  t('Bystry'),
  t('Senny'),
  t('Błękitny'),
];

List<String> get _animals => <String>[
  t('Lis'),
  t('Jeż'),
  t('Borsuk'),
  t('Wilk'),
  t('Sokół'),
  t('Kos'),
  t('Dzik'),
  t('Bóbr'),
  t('Żuraw'),
  t('Łoś'),
  t('Rys'),
  t('Orzeł'),
  t('Szop'),
  t('Kruk'),
  t('Puszczyk'),
  t('Delfin'),
];

/// A friendly name for a stranger's token ("Zielony Lis").
String nearbyPseudonym(List<int> token) {
  final List<int> h = crypto.sha256.convert(token).bytes;
  final List<String> adjectives = _adjectives;
  final List<String> animals = _animals;
  return t('{adjective} {animal}', {
    'adjective': adjectives[h[0] % adjectives.length],
    'animal': animals[h[1] % animals.length],
  });
}

/// How close, from the signal strength.
String nearbyDistance(int rssi) {
  if (rssi >= -60) {
    return t('blisko');
  }
  if (rssi >= -80) {
    return t('w pokoju');
  }
  return t('dalej');
}

/// Signal strength of a phone heard only on the shared network.
const int kNearbyNoSignal = -127;

/// Slots of tokens handed to the network at once (a day); worked out again
/// once half of them are gone.
const int kNearbyNetworkSlots = 144;

/// How often the network is read while looking around.
const Duration kNearbyNetworkRead = Duration(seconds: 3);

/// The shared local network (the same Wi-Fi or router) as a second way to
/// people nearby, next to Bluetooth: the very adverts of the radio (token
/// and hint) ride on the network's beacons
/// (native/yggdrasil_bridge/lan_nearby.go), so friends recognise this phone
/// there as over Bluetooth and everyone else sees the same changing
/// pseudonym. No address goes out, and nobody is written to over it.
abstract interface class NearbyNetwork {
  /// Shows [adverts] ([kNearbyAdvertBytes] per slot from [firstSlot] on: the
  /// other side picks the one of the slot it is in, and shows nothing once
  /// they are over) or nothing (`null`), and looks around or not.
  void update({
    required int firstSlot,
    required Uint8List? adverts,
    required bool looking,
  });

  /// Adverts heard lately while looking around ([kNearbyAdvertBytes]
  /// each), with when (milliseconds since the epoch).
  List<(Uint8List, int)> heard();
}

/// The Bluetooth radio (native in the app, a fake in tests).
abstract interface class NearbyRadio {
  Stream<Map<Object?, Object?>> get events;
  Future<Map<Object?, Object?>> state();
  Future<bool> requestPermissions();

  /// Asks the person to switch Bluetooth on (the system dialog). Returns
  /// whether it is on already; a change comes later as a `bluetooth` event.
  Future<bool> requestEnable();
  Future<bool> startAdvertising(Uint8List token);

  /// Shows [adverts] ([kNearbyAdvertBytes] per slot, from [firstSlot] on)
  /// each in its own slot: the radio side changes the token (and with it
  /// the Bluetooth address) at every slot by itself, without waking Dart,
  /// and shows nothing once the list is over.
  Future<bool> startAdvertisingSchedule(int firstSlot, Uint8List adverts);
  Future<void> stopAdvertising();
  Future<bool> startScan({bool lowPower = false});
  Future<void> stopScan();
  Future<bool> wave(String device, Uint8List data);
}

final class ChannelNearbyRadio implements NearbyRadio {
  static const MethodChannel _channel = MethodChannel('zen/nearby');
  static const EventChannel _events = EventChannel('zen/nearby/events');

  /// One subscription per isolate, shared by every radio object in it: a
  /// second `listen` on the same channel would take the events away from
  /// the first (the background service makes a new one per run).
  static final Stream<Map<Object?, Object?>> _stream = _events
      .receiveBroadcastStream()
      .where((Object? e) => e is Map)
      .cast<Map<Object?, Object?>>()
      .handleError((Object error) => logZenWarning('W pobliżu: $error'));

  bool get _supported => !kIsWeb && Platform.isAndroid;

  Future<T?> _call<T>(String method, [Object? args]) async {
    if (!_supported) {
      return null;
    }
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      logZenWarning('W pobliżu ($method): ${error.message}');
      return null;
    }
  }

  @override
  Stream<Map<Object?, Object?>> get events =>
      _supported ? _stream : const Stream<Map<Object?, Object?>>.empty();

  @override
  Future<Map<Object?, Object?>> state() async =>
      await _call<Map<Object?, Object?>>('state') ??
      const <Object?, Object?>{'supported': false};

  @override
  Future<bool> requestPermissions() async =>
      await _call<bool>('requestPermissions') ?? false;

  @override
  Future<bool> requestEnable() async =>
      await _call<bool>('requestEnable') ?? false;

  @override
  Future<bool> startAdvertising(Uint8List token) async =>
      await _call<bool>('startAdvertising', <String, Object>{'token': token}) ??
      false;

  @override
  Future<bool> startAdvertisingSchedule(
    int firstSlot,
    Uint8List adverts,
  ) async =>
      await _call<bool>('startAdvertisingSchedule', <String, Object>{
        'start': firstSlot,
        'adverts': adverts,
      }) ??
      false;

  @override
  Future<void> stopAdvertising() => _call<void>('stopAdvertising');

  @override
  Future<bool> startScan({bool lowPower = false}) async =>
      await _call<bool>('startScan', <String, Object>{'lowPower': lowPower}) ??
      false;

  @override
  Future<void> stopScan() => _call<void>('stopScan');

  @override
  Future<bool> wave(String device, Uint8List data) async =>
      await _call<bool>('wave', <String, Object>{
        'device': device,
        'data': data,
      }) ??
      false;

  /// The background service answers alarm waves from now on (or no
  /// longer): the app then leaves them to it, so an alarm rings once.
  Future<void> setAlarmReceiver(bool on) => _call<void>('setAlarmReceiver', on);

  /// Friends' keys for alarm waves ([FriendNearbyKey.radioKey]: a pair key
  /// `p:…`): the radio side checks an
  /// alarm wave's signature with them before counting it, so a flood of
  /// other waves cannot crowd a friend's alarm out.
  Future<void> setAlarmKeys(List<String> secrets) =>
      _call<void>('setAlarmKeys', secrets);
}

/// Someone whose phone is nearby right now.
final class NearbyPerson {
  NearbyPerson({
    required this.token,
    required this.device,
    required this.rssi,
    required this.seenAt,
    this.friend,
    this.networkSeenAt = 0,
  });

  final String token;

  /// Its Bluetooth address ('' when only heard on the shared network).
  String device;
  int rssi;
  int seenAt;

  /// When it was last heard on the shared network (0: never).
  int networkSeenAt;

  /// A friend's address when the token is theirs.
  final String? friend;

  String get pseudonym => nearbyPseudonym(_unhex(token));

  /// Seen over Bluetooth: it can be written to.
  bool get overBluetooth => device.isNotEmpty;

  /// How close ([nearbyDistance]); a phone heard only on the shared network
  /// has no signal to tell it by.
  String get distance =>
      overBluetooth ? nearbyDistance(rssi) : t('w tej samej sieci');
}

List<int> _unhex(String hex) => <int>[
  for (int i = 0; i + 1 < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

String _clip(String text, int max) =>
    text.length > max ? text.substring(0, max) : text;

/// One line of a conversation started nearby.
@immutable
final class NearbyLine {
  const NearbyLine(this.mine, this.text, this.at);

  final bool mine;
  final String text;
  final int at;
}

/// A conversation with someone nearby, without either side's account.
final class NearbySession {
  NearbySession({
    required this.id,
    required this.pseudonym,
    this.address,
    this.startedByMe = false,
    this.peerToken = '',
  });

  final String id;
  String pseudonym;

  /// Their mesh address (known once they answered).
  String? address;
  final bool startedByMe;

  /// The other phone's token when the conversation started (badges).
  final String peerToken;
  final List<NearbyLine> lines = <NearbyLine>[];

  /// The seed of this phone's one-time hello key (memory only).
  Uint8List? _helloSeed;

  /// The one-time hybrid public key of their hello (memory only).
  Uint8List? _peerPublic;

  /// The key both sides worked out from the hello and the answer.
  List<int>? _shared;

  bool get theyWrote => lines.any((NearbyLine l) => !l.mine);
  bool get iAnswered => lines.any((NearbyLine l) => l.mine);

  /// One message to a stranger until they answer; one answer over
  /// Bluetooth to a hello without an address, then the hello's author
  /// writes first over the network.
  bool get canSend {
    if (startedByMe) {
      return address != null && theyWrote;
    }
    if (address != null) {
      return true;
    }
    return _peerPublic != null && !iAnswered;
  }

  /// This person answered a hello without an address and waits for its
  /// author to write over the network.
  bool get waitsForThem => !startedByMe && address == null && iAnswered;
}

/// "Osoby w pobliżu": shows this phone to people around (friends
/// recognise it, strangers see a changing pseudonym), lists who is near
/// and lets strangers say hello. A friend seen here is only a hint: "met
/// in person" is signed only when the person confirms it.
final class NearbyService extends ChangeNotifier {
  NearbyService({
    required this.radio,
    required this.meet,
    required this.ownAddress,
    required this.sendMesh,
    required Stream<SignalTransportFrame> frames,
    this.network,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure() {
    _subs
      ..add(radio.events.listen(_onRadio))
      ..add(frames.listen(_onFrame));
  }

  final NearbyRadio radio;

  /// The shared local network, next to the radio (`null`: none).
  final NearbyNetwork? network;
  final MeetService meet;
  final String Function() ownAddress;
  final Future<void> Function(String to, Map<String, dynamic> payload) sendMesh;

  final int Function() _now;
  final Random _random;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  static final cg.Chacha20 _aead = cg.Chacha20.poly1305Aead();

  /// Parts of hello keys and answer ciphertexts heard over Bluetooth.
  final NearbyPieces _pieces = NearbyPieces();

  /// Hellos and answers whose key or ciphertext has not come whole yet
  /// (`what|sid` → the message), at most [kNearbyMaxPieces].
  final Map<String, Map<dynamic, dynamic>> _waitingForPiece =
      <String, Map<dynamic, dynamic>>{};

  final Map<String, NearbyPerson> _people = <String, NearbyPerson>{};
  final Map<String, NearbySession> _sessions = <String, NearbySession>{};

  /// Blocked just now (the book keeps them for good,
  /// [MeetService.blockNearby]); hellos without an address are blocked by
  /// token.
  final Set<String> _blockedNow = <String>{};
  final Set<String> _blockedTokens = <String>{};

  /// Friends' keys as read from the book, and what was worked out of them
  /// for the slots around now.
  Map<String, FriendNearbyKey> _friendKeys = <String, FriendNearbyKey>{};
  Map<String, String> _friendKeyText = <String, String>{};
  Map<String, List<(String, int)>> _hints = <String, List<(String, int)>>{};
  Map<String, String> _pairIds = <String, String>{};
  int _keysSlot = -1;

  /// Per friend: the last checked chain value (its slot), so the next
  /// check is a few hashes.
  final Map<String, (int, List<int>)> _checked = <String, (int, List<int>)>{};

  /// Tokens recognised as a friend's (token → friend, slot).
  final Map<String, (String, int)> _recognised = <String, (String, int)>{};

  NearbyOwnKeys? _own;
  String? _ownFrom;

  /// This phone's token of [_myTokenSlot] (hex), worked out once a slot: it
  /// is checked against every advert heard.
  String _myToken = '';
  int _myTokenSlot = -1;
  NearbyOwnKeys? _myTokenKeys;

  /// What the network was given: tokens from [_networkFirst] on, and
  /// whether it looks around ([_networkTimer] reads it meanwhile).
  int _networkFirst = 0;
  Uint8List? _networkAdverts;
  NearbyOwnKeys? _networkKeys;
  bool _networkLook = false;
  Timer? _networkTimer;

  /// How often the network is read while looking around.
  Duration networkEvery = kNearbyNetworkRead;

  /// The friends' keys last handed to the radio ([_pushAlarmKeys]).
  String? _alarmKeysGiven;
  int _advertisedSlot = -1;
  bool visible = false;
  bool scanning = false;

  /// How long an answer over Bluetooth first looks for phones around when
  /// nothing is scanning.
  Duration replyListen = const Duration(seconds: 6);

  /// The scan running now is only a short look around ([scanWindow]).
  bool _windowOpen = false;

  /// Waves of other kinds (a flat's invitation, a crisis
  /// announcement): each handler picks its own version.
  final List<void Function(Map<dynamic, dynamic> json)> otherWaveHandlers =
      <void Function(Map<dynamic, dynamic> json)>[];

  /// Alarm waves ([kAlarmWaveVersion]) with
  /// the Bluetooth address of the phone that wrote them (for limits on what
  /// strangers send).
  final List<void Function(Map<dynamic, dynamic> json, String device)>
  alarmWaveHandlers =
      <void Function(Map<dynamic, dynamic> json, String device)>[];

  /// Bluetooth was switched on (`true`) or off on this phone.
  final List<void Function(bool on)> bluetoothHandlers =
      <void Function(bool on)>[];

  /// "Mijani": told about every phone seen while something scans
  /// anyway (no scanning of its own), written when a scan ends.
  EncounterLog? encounters;
  Timer? _tick;

  /// Seen within this long counts as "here".
  static const Duration fresh = Duration(minutes: 2);

  /// Conversations started by people nearby kept at most, and per address
  /// (or token) they came from (a wave is free to send, so a phone nearby
  /// could otherwise fill the list without end). Of those, one at a time
  /// may wait for this person's answer (one message from a stranger
  /// until you answer).
  static const int maxSessions = 50;
  static const int maxSessionsPerAddress = 3;

  /// Phones seen nearby kept at most (the ones not seen for a while go).
  static const int maxPeople = 300;

  List<NearbyPerson> get people {
    final int t = _now();
    return _people.values
        .where((NearbyPerson p) => t - p.seenAt < fresh.inMilliseconds)
        .toList()
      ..sort((NearbyPerson a, NearbyPerson b) {
        if ((a.friend == null) != (b.friend == null)) {
          return a.friend == null ? 1 : -1;
        }
        return b.rssi.compareTo(a.rssi);
      });
  }

  List<NearbySession> get sessions => _sessions.values.toList();

  NearbySession? session(String id) => _sessions[id];

  /// The conversations with the phone that shows [token].
  Iterable<NearbySession> sessionsWith(String token) => _sessions.values.where(
    (NearbySession s) => token.isNotEmpty && s.peerToken == token,
  );

  NearbyOwnKeys? get _ownKeys {
    final String? private = meet.book.nearbyPrivate;
    if (private == null) {
      return null;
    }
    if (private != _ownFrom) {
      _ownFrom = private;
      try {
        _own = NearbyOwnKeys(private);
      } on FormatException {
        _own = null;
      }
    }
    return _own;
  }

  /// The token this phone shows now (hex), '' before it has a key.
  String get myToken {
    final NearbyOwnKeys? keys = _ownKeys;
    if (keys == null) {
      return '';
    }
    final int slot = nearbySlot(_now());
    if (slot != _myTokenSlot || !identical(keys, _myTokenKeys)) {
      _myTokenSlot = slot;
      _myTokenKeys = keys;
      _myToken = _hex(keys.token(slot));
    }
    return _myToken;
  }

  /// Looking around: over Bluetooth ([scanning]), on the network, or both.
  bool get looking => scanning || _networkLook;

  String get myPseudonym {
    final String token = myToken;
    return token.isEmpty ? t('Ktoś obok') : nearbyPseudonym(_unhex(token));
  }

  /// Reads the friends' keys again when the slot changed, or always with
  /// [force].
  void _refreshFriendKeys({bool force = false}) {
    final int slot = nearbySlot(_now());
    if (!force && slot == _keysSlot) {
      return;
    }
    _keysSlot = slot;
    final Map<String, String> stored = Map<String, String>.of(
      meet.book.friendNearbySecrets,
    );
    final Map<String, FriendNearbyKey> keys = <String, FriendNearbyKey>{};
    final Map<String, List<(String, int)>> hints =
        <String, List<(String, int)>>{};
    final Map<String, String> pairIds = <String, String>{};
    for (final MapEntry<String, String> e in stored.entries) {
      final String friend = e.key;
      final FriendNearbyKey? key = FriendNearbyKey.parse(e.value);
      if (key == null) {
        continue;
      }
      keys[friend] = key;
      for (int s = slot - 1; s <= slot + 1; s++) {
        (hints[_hex(nearbyHint(key.mask, s))] ??= <(String, int)>[]).add((
          friend,
          s,
        ));
      }
      for (int s = slot - 2; s <= slot + 2; s++) {
        pairIds[nearbyPairId(key.pair, s)] = friend;
      }
    }
    final Set<String> changed = <String>{
      for (final String f in <String>{..._friendKeyText.keys, ...stored.keys})
        if (_friendKeyText[f] != stored[f]) f,
    };
    _checked.removeWhere((String f, (int, List<int>) _) => changed.contains(f));
    _recognised.removeWhere(
      (String _, (String, int) v) =>
          changed.contains(v.$1) || (slot - v.$2).abs() > 2,
    );
    _friendKeyText = stored;
    _friendKeys = keys;
    _hints = hints;
    _pairIds = pairIds;
    _pushAlarmKeys(keys.values);
  }

  /// Hands friends' alarm keys to the native radio (when they changed),
  /// which checks a friend's signed alarm wave before its limits for
  /// strangers apply.
  void _pushAlarmKeys(Iterable<FriendNearbyKey> keys) {
    final NearbyRadio r = radio;
    if (r is! ChannelNearbyRadio) {
      return;
    }
    final List<String> given =
        keys.map((FriendNearbyKey k) => k.radioKey).toSet().toList()..sort();
    final String joined = given.join('\n');
    if (joined == _alarmKeysGiven) {
      return;
    }
    _alarmKeysGiven = joined;
    unawaitedLogged(r.setAlarmKeys(given), context: 'W pobliżu: klucze alarmu');
  }

  /// Friends' keys changed (a new friend, renewed keys).
  void friendsChanged() => _refreshFriendKeys(force: true);

  /// Shows this phone to people nearby (and keeps the token fresh).
  Future<bool> setVisible(bool on) async {
    visible = on;
    if (!on) {
      _advertisedSlot = -1;
      _pushNetwork();
      await radio.stopAdvertising();
      _syncTimer();
      notifyListeners();
      return true;
    }
    final bool ok = await _advertise(force: true);
    _syncTimer();
    notifyListeners();
    return ok;
  }

  /// Shows the token of the current slot. A new token restarts advertising,
  /// which gives the phone a new Bluetooth address with it.
  Future<bool> _advertise({bool force = false}) async {
    final int slot = nearbySlot(_now());
    if (!force && slot == _advertisedSlot) {
      return true;
    }
    await meet.nearbyPrivateKey();
    final NearbyOwnKeys? keys = _ownKeys;
    if (keys == null) {
      return false;
    }
    // On the network too, also while Bluetooth is off.
    _showOnNetwork(keys, slot);
    final bool ok = await radio.startAdvertising(keys.advert(slot));
    _advertisedSlot = ok ? slot : -1;
    return ok;
  }

  /// Hands the network this phone's tokens from [slot] on (worked out again
  /// once half of them are gone, or for a new key).
  void _showOnNetwork(NearbyOwnKeys keys, int slot) {
    if (network == null) {
      return;
    }
    if (_networkAdverts == null ||
        !identical(keys, _networkKeys) ||
        slot < _networkFirst ||
        slot >= _networkFirst + kNearbyNetworkSlots ~/ 2) {
      _networkKeys = keys;
      _networkFirst = slot;
      _networkAdverts = keys.adverts(slot, kNearbyNetworkSlots);
    }
    _pushNetwork();
  }

  void _pushNetwork() {
    network?.update(
      firstSlot: _networkFirst,
      adverts: visible ? _networkAdverts : null,
      looking: _networkLook,
    );
  }

  /// Looks around on the network (or stops): its beacons ask the phones
  /// there to answer, and what is heard is read every
  /// [networkEvery].
  void _lookOnNetwork(bool on) {
    if (network == null || on == _networkLook) {
      return;
    }
    _networkTimer?.cancel();
    _networkTimer = null;
    if (!on) {
      // What came until now still counts.
      _readNetwork();
    }
    _networkLook = on;
    _pushNetwork();
    if (on) {
      _networkTimer = Timer.periodic(networkEvery, (_) => _readNetwork());
    }
  }

  void _readNetwork() {
    final NearbyNetwork? net = network;
    if (net == null || !_networkLook) {
      return;
    }
    final List<(Uint8List, int)> heard;
    try {
      heard = net.heard();
    } on Object catch (error) {
      logZenWarning('W pobliżu (sieć): $error');
      return;
    }
    final int t = _now();
    for (final (Uint8List advert, int at) in heard) {
      if (advert.length != kNearbyAdvertBytes) {
        continue;
      }
      _seen(
        advert.sublist(0, 16),
        advert.sublist(16, kNearbyAdvertBytes),
        at: min(at, t),
      );
    }
  }

  Future<bool> startScanning({bool lowPower = false}) async {
    // Whoever asks now owns the scan: a short look around running
    // meanwhile no longer ends it.
    _windowOpen = false;
    return _startScan(lowPower: lowPower);
  }

  Future<bool> _startScan({required bool lowPower}) async {
    friendsChanged();
    // The network needs no permission and works with Bluetooth off.
    _lookOnNetwork(true);
    scanning = await radio.startScan(lowPower: lowPower);
    _syncTimer();
    notifyListeners();
    return scanning;
  }

  Future<void> stopScanning() async {
    _windowOpen = false;
    _lookOnNetwork(false);
    scanning = false;
    await radio.stopScan();
    _syncTimer();
    notifyListeners();
    // One write per look around in the background.
    final EncounterLog? log = encounters;
    if (log != null) {
      unawaitedLogged(log.flush(), context: 'Mijani: zapis');
    }
  }

  /// One short, low-power look around (without the "W pobliżu" screen
  /// the phone only peeks now and then, to save the battery). Who is in
  /// range goes to "Mijani" ([encounters]). Skipped while something else
  /// is scanning; whoever starts scanning meanwhile takes the scan over.
  /// Returns whether it ran.
  Future<bool> scanWindow(Duration length) async {
    if (scanning) {
      return false;
    }
    _windowOpen = true;
    if (!await _startScan(lowPower: true)) {
      _windowOpen = false;
      _lookOnNetwork(false);
      return false;
    }
    await Future<void>.delayed(length);
    if (_windowOpen) {
      await stopScanning();
    }
    return true;
  }

  void _syncTimer() {
    if (!visible && !looking) {
      _tick?.cancel();
      _tick = null;
      return;
    }
    _tick ??= Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshFriendKeys();
      if (visible) {
        unawaitedLogged(_advertise(), context: 'W pobliżu: nowy token');
      }
      notifyListeners();
    });
  }

  void _onRadio(Map<Object?, Object?> event) {
    switch (event['type']) {
      case 'seen':
        final Object? token = event['token'];
        final Object? hint = event['hint'];
        final Object? device = event['device'];
        final Object? rssi = event['rssi'];
        if (token is! List<int> ||
            token.length < 16 ||
            device is! String ||
            rssi is! int) {
          return;
        }
        // The native side splits the hint off; a radio that does not
        // hands the whole advert.
        List<int>? h = hint is List<int> && hint.length == kNearbyHintLength
            ? hint
            : null;
        if (h == null && token.length >= 16 + kNearbyHintLength) {
          h = token.sublist(16, 16 + kNearbyHintLength);
        }
        if (h == null) {
          return;
        }
        _seen(token.sublist(0, 16), h, device: device, rssi: rssi);
      case 'wave':
        final Object? data = event['data'];
        final Object? writer = event['device'];
        if (data is List<int>) {
          _onWave(
            Uint8List.fromList(data),
            device: writer is String ? writer : '',
            alarmsElsewhere: event['elsewhere'] == true,
          );
        }
      case 'bluetooth':
        final bool on = event['on'] == true;
        if (!on) {
          // The radio forgot what it showed; shown again once it is back.
          _advertisedSlot = -1;
        }
        for (final void Function(bool) h in bluetoothHandlers.toList()) {
          h(on);
        }
        notifyListeners();
    }
  }

  /// A Zen phone nearby showed [raw] (16 bytes) with [hint]: over
  /// Bluetooth from [device] with [rssi], or (without them) on the shared
  /// network at [at].
  void _seen(
    List<int> raw,
    List<int> hint, {
    String? device,
    int? rssi,
    int? at,
  }) {
    final String token = _hex(raw);
    if (token == myToken) {
      return;
    }
    final int t = at ?? _now();
    final NearbyPerson? had = _people[token];
    if (device == null && had != null && had.networkSeenAt >= t) {
      // Read from the network again: nothing new.
      return;
    }
    _refreshFriendKeys();
    final String? friend = _recognise(raw, _hex(hint), token);
    // Only who (a friend) or how many (anyone else) — never the address.
    encounters?.saw(token: token, at: t, friend: friend);
    if (had != null) {
      if (device != null) {
        had
          ..device = device
          ..rssi = rssi ?? had.rssi;
      } else {
        had.networkSeenAt = t;
      }
      had.seenAt = max(had.seenAt, t);
    } else {
      if (_people.length >= maxPeople) {
        _people.removeWhere(
          (String _, NearbyPerson p) => t - p.seenAt >= fresh.inMilliseconds,
        );
        while (_people.length >= maxPeople) {
          _people.remove(_people.keys.first);
        }
      }
      _people[token] = NearbyPerson(
        token: token,
        device: device ?? '',
        rssi: rssi ?? kNearbyNoSignal,
        seenAt: t,
        friend: friend,
        networkSeenAt: device == null ? t : 0,
      );
    }
    notifyListeners();
  }

  /// The friend whose token [raw] is: the hint names the candidates, the
  /// hash chain proves it (a friend who knows the mask cannot make it).
  String? _recognise(List<int> raw, String hint, String token) {
    final (String, int)? known = _recognised[token];
    if (known != null) {
      return known.$1;
    }
    for (final (String friend, int slot) in _hints[hint] ?? <(String, int)>[]) {
      final FriendNearbyKey? key = _friendKeys[friend];
      final (int, List<int>)? last = _checked[friend];
      final List<int>? value = key?.open(raw, slot, last: last);
      if (value == null) {
        continue;
      }
      if (last == null || last.$1 <= slot) {
        _checked[friend] = (slot, value);
      }
      if (_recognised.length >= maxPeople) {
        _recognised.remove(_recognised.keys.first);
      }
      _recognised[token] = (friend, slot);
      return friend;
    }
    return null;
  }

  // ---- talking to strangers ----

  String _newId() => List<String>.generate(
    12,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  static Uint8List _encode(Map<String, dynamic> json) =>
      Uint8List.fromList(utf8.encode(jsonEncode(json)));

  /// Says hello to [person] over Bluetooth: they get this phone's pseudonym
  /// and [text] — no account and no address; the address goes only to
  /// someone who answers ([kNearbyReplyVersion]).
  Future<NearbySession?> wave(NearbyPerson person, String text) async {
    final String message = _clip(text.trim(), kNearbyHelloMaxLength);
    if (ownAddress().isEmpty || message.isEmpty || !person.overBluetooth) {
      return null;
    }
    await meet.nearbyPrivateKey();
    final String id = _newId();
    final Uint8List seed = randomHybridSeed();
    final Uint8List publicKey = await hybridKem.publicKeyOf(seed);
    final Map<String, dynamic> json = <String, dynamic>{
      'v': kNearbyHelloVersion,
      'sid': id,
      'n': myPseudonym,
      't': myToken,
      'kh': nearbyPieceId(publicKey),
      'm': message,
    };
    // The key first, in parts; the hello last.
    for (final Map<String, dynamic> w in <Map<String, dynamic>>[
      ...nearbyParts(id, 'h', publicKey),
      json,
    ]) {
      if (!await radio.wave(person.device, _encode(w))) {
        return null;
      }
    }
    final NearbySession s =
        NearbySession(
            id: id,
            pseudonym: person.pseudonym,
            startedByMe: true,
            peerToken: person.token,
          )
          .._helloSeed = seed
          ..lines.add(NearbyLine(true, message, _now()));
    _sessions[id] = s;
    notifyListeners();
    return s;
  }

  /// Sends [json] over Bluetooth to every phone around right now ([only]:
  /// to those it picks). Returns how many got it.
  ///
  /// An alarm wave ([kAlarmWaveVersion], unsigned) goes to a friend
  /// signed with the key of that pair instead: only they can check it.
  Future<int> waveAll(
    Map<String, dynamic> json, {
    bool Function(NearbyPerson person)? only,
  }) async {
    final Uint8List data = _encode(json);
    final AlarmWave? alarm = json['v'] == kAlarmWaveVersion
        ? AlarmWave.parse(json)
        : null;
    final NearbyOwnKeys? own = alarm == null ? null : _ownKeys;
    if (alarm != null) {
      _refreshFriendKeys();
    }
    int sent = 0;
    for (final NearbyPerson p in people) {
      if (!p.overBluetooth || (only != null && !only(p))) {
        continue;
      }
      Uint8List out = data;
      final String? friend = p.friend;
      if (alarm != null &&
          own != null &&
          friend != null &&
          _friendKeys.containsKey(friend)) {
        out = _encode(
          AlarmWave.buildPair(
            id: alarm.id,
            at: alarm.at,
            ended: alarm.ended,
            pairKey: own.pairKey(friend),
          ),
        );
      }
      if (await radio.wave(p.device, out)) {
        sent++;
      }
    }
    return sent;
  }

  /// Like [waveAll], but when the radio is not scanning it first looks
  /// around for [listen] (to find the phones to send to) and then stops
  /// again (an alarm told to phones nearby).
  Future<int> waveAround(
    Map<String, dynamic> json, {
    Duration listen = const Duration(seconds: 6),
    bool Function(NearbyPerson person)? only,
  }) => _lookAroundAnd(listen, () => waveAll(json, only: only));

  /// Runs [send] while scanning: when the radio is not scanning it first
  /// looks around for [listen] and stops again after.
  Future<int> _lookAroundAnd(
    Duration listen,
    Future<int> Function() send,
  ) async {
    // A short look around does not count: it would end halfway through.
    final bool wasScanning = scanning && !_windowOpen;
    if (!wasScanning) {
      if (!await startScanning(lowPower: false)) {
        return 0;
      }
      await Future<void>.delayed(listen);
    }
    try {
      return await send();
    } finally {
      if (!wasScanning) {
        await stopScanning();
      }
    }
  }

  /// Sends [waves] one after another to every phone around ([only]: to
  /// those it picks); how many got them all.
  Future<int> _waveEach(
    List<Map<String, dynamic>> waves,
    bool Function(NearbyPerson person)? only,
  ) async {
    int sent = 0;
    for (final NearbyPerson p in people) {
      if (!p.overBluetooth || (only != null && !only(p))) {
        continue;
      }
      bool all = true;
      for (final Map<String, dynamic> w in waves) {
        if (!await radio.wave(p.device, _encode(w))) {
          all = false;
          break;
        }
      }
      if (all) {
        sent++;
      }
    }
    return sent;
  }

  /// The friend whose alarm-wave token [token] (hex) is — a pair's id — or
  /// `null` for a stranger.
  String? friendOfToken(Object? token) {
    if (token is! String || token.isEmpty) {
      return null;
    }
    _refreshFriendKeys();
    return _pairIds[token];
  }

  /// [device]: the Bluetooth address of the phone that wrote it.
  /// [alarmsElsewhere]: another part of the app (the Android background
  /// service, or the app itself) answers alarm waves right now, so they are
  /// not handed on here — the alarm rings once.
  void _onWave(
    Uint8List data, {
    String device = '',
    bool alarmsElsewhere = false,
  }) {
    try {
      final Object? json = jsonDecode(utf8.decode(data));
      if (json is! Map) {
        return;
      }
      final Object? v = json['v'];
      if (v == kAlarmWaveVersion) {
        if (alarmsElsewhere) {
          return;
        }
        for (final void Function(Map<dynamic, dynamic>, String) h
            in alarmWaveHandlers.toList()) {
          h(json, device);
        }
        return;
      }
      if (v == kNearbyPartVersion) {
        _onPart(json);
      } else if (v == kNearbyHelloVersion) {
        _onHello(json);
      } else if (v == kNearbyReplyVersion) {
        unawaitedLogged(_onReply(json), context: 'W pobliżu: odpowiedź');
      } else {
        for (final void Function(Map<dynamic, dynamic>) h
            in otherWaveHandlers) {
          h(json);
        }
      }
    } on Object catch (error) {
      logZenWarning('W pobliżu: niezrozumiałe przywitanie: $error');
    }
  }

  bool _isBlocked(String address) {
    final String a = PeerShareCodec.normalizeAddress(address);
    return _blockedNow.contains(a) || meet.book.nearbyBlocked.contains(a);
  }

  /// Whether one more hello from the same sender ([same]) is taken: at most
  /// [maxSessionsPerAddress] conversations, and none still waiting for this
  /// person's answer (one message from a stranger until you answer).
  bool _roomFor(bool Function(NearbySession s) same) {
    final List<NearbySession> theirs = _sessions.values
        .where((NearbySession x) => !x.startedByMe && same(x))
        .toList();
    if (theirs.length >= maxSessionsPerAddress ||
        theirs.any((NearbySession x) => !x.iAnswered)) {
      return false;
    }
    return _sessions.length < maxSessions || _dropOldSession();
  }

  static final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');

  /// A part of a hello's key or an answer's ciphertext: a hello or an
  /// answer that waited for it goes on once it is whole.
  void _onPart(Map<dynamic, dynamic> json) {
    final (String, String)? done = _pieces.add(json, _now());
    if (done == null) {
      return;
    }
    final Map<dynamic, dynamic>? waiting = _waitingForPiece.remove(
      '${done.$2}|${done.$1}',
    );
    if (waiting == null) {
      return;
    }
    if (done.$2 == 'h') {
      _onHello(waiting);
    } else {
      unawaitedLogged(_onReply(waiting), context: 'W pobliżu: odpowiedź');
    }
  }

  /// The piece [json] names under [field] ([what]: `h` or `r`), or `null`
  /// when it has not come whole yet: then [json] waits for it.
  Uint8List? _pieceFor(
    Map<dynamic, dynamic> json,
    String what,
    String field,
    String sid,
  ) {
    final Object? id = json[field];
    if (id is! String || id.length != 24) {
      return null;
    }
    final Uint8List? bytes = _pieces.take(sid, what, id, _now());
    if (bytes == null) {
      final String key = '$what|$sid';
      if (!_waitingForPiece.containsKey(key)) {
        while (_waitingForPiece.length >= kNearbyMaxPieces) {
          _waitingForPiece.remove(_waitingForPiece.keys.first);
        }
        _waitingForPiece[key] = json;
      }
    }
    return bytes;
  }

  /// A hello without an address ([kNearbyHelloVersion]).
  void _onHello(Map<dynamic, dynamic> json) {
    final Object? id = json['sid'];
    final Object? name = json['n'];
    final Object? token = json['t'];
    final Object? text = json['m'];
    if (id is! String ||
        !kAlarmIdPattern.hasMatch(id) ||
        name is! String ||
        token is! String ||
        !_hex32.hasMatch(token) ||
        text is! String ||
        _blockedTokens.contains(token) ||
        _sessions.containsKey(id)) {
      return;
    }
    final Uint8List? publicKey = _pieceFor(json, 'h', 'kh', id);
    if (publicKey == null || publicKey.length != kHybridPublicKeyBytes) {
      return;
    }
    if (!_roomFor((NearbySession x) => x.peerToken == token)) {
      return;
    }
    _sessions[id] =
        NearbySession(id: id, pseudonym: _clip(name, 40), peerToken: token)
          .._peerPublic = publicKey
          ..lines.add(
            NearbyLine(false, _clip(text, kNearbyHelloMaxLength), _now()),
          );
    notifyListeners();
  }

  /// What the hybrid KEM binds the secret of a hello's answer to.
  static List<int> _kemInfo(String sid) => utf8.encode('zen-nearby-hello|$sid');

  /// The key of a hello and its answer: the hybrid KEM's secret, bound to
  /// the conversation, the hello's key and the answer's ciphertext.
  static List<int> _sharedKey(
    List<int> secret, {
    required String sid,
    required List<int> helloPublic,
    required List<int> ciphertext,
  }) => crypto.sha256.convert(<int>[
    ...utf8.encode('zen-nearby-hello-v2|$sid|'),
    ...secret,
    ...crypto.sha256.convert(helloPublic).bytes,
    ...crypto.sha256.convert(ciphertext).bytes,
  ]).bytes;

  static List<int> _replyAad(String sid) =>
      utf8.encode('zen-nearby-reply|$sid');

  /// What the hello's author adds to the first network message: proof that
  /// they hold the hello's key (the conversation id went over the air).
  static String _bindProof(List<int> shared, String sid) => _hex(
    crypto.Hmac(
      crypto.sha256,
      shared,
    ).convert(utf8.encode('zen-nearby-bind|$sid')).bytes.sublist(0, 16),
  );

  /// The answer to a hello without an address: sealed for the hello's
  /// one-time key and written to the phones around (only that phone can
  /// open it; it no longer shows the same token after a few minutes).
  Future<bool> _answerOverAir(NearbySession s, String text) async {
    final Uint8List? theirs = s._peerPublic;
    final String address = ownAddress();
    if (theirs == null || address.isEmpty) {
      return false;
    }
    final HybridEncapsulation kem = await hybridKem.encapsulate(
      theirs,
      info: _kemInfo(s.id),
    );
    final List<int> shared = _sharedKey(
      kem.secret,
      sid: s.id,
      helloPublic: theirs,
      ciphertext: kem.ciphertext,
    );
    kem.secret.fillRange(0, kem.secret.length, 0);
    final List<int> nonce = List<int>.generate(12, (_) => _random.nextInt(256));
    final cg.SecretBox box = await _aead.encrypt(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'a': address,
          'n': myPseudonym,
          'm': text,
        }),
      ),
      secretKey: cg.SecretKey(shared),
      nonce: nonce,
      aad: _replyAad(s.id),
    );
    final List<Map<String, dynamic>> waves = <Map<String, dynamic>>[
      ...nearbyParts(s.id, 'r', kem.ciphertext),
      <String, dynamic>{
        'v': kNearbyReplyVersion,
        'sid': s.id,
        'ch': nearbyPieceId(kem.ciphertext),
        'c': base64Url.encode(<int>[
          ...nonce,
          ...box.cipherText,
          ...box.mac.bytes,
        ]),
      },
    ];
    // Only to the phone that said hello when it still shows the same
    // token (the answer is longer now); else to every phone around.
    final bool seen = people.any(
      (NearbyPerson p) => p.token == s.peerToken && p.overBluetooth,
    );
    final int sent = await _lookAroundAnd(
      replyListen,
      () => _waveEach(
        waves,
        seen && s.peerToken.isNotEmpty
            ? (NearbyPerson p) => p.token == s.peerToken
            : null,
      ),
    );
    if (sent == 0) {
      return false;
    }
    s._shared = shared;
    return true;
  }

  /// An answer to this phone's hello without an address.
  Future<void> _onReply(Map<dynamic, dynamic> json) async {
    final Object? id = json['sid'];
    final Object? sealed = json['c'];
    final NearbySession? s = id is String ? _sessions[id] : null;
    final Uint8List? seed = s?._helloSeed;
    if (s == null ||
        seed == null ||
        !s.startedByMe ||
        s.address != null ||
        sealed is! String ||
        sealed.length > 2048) {
      return;
    }
    final Uint8List? ciphertext = _pieceFor(json, 'r', 'ch', s.id);
    if (ciphertext == null || ciphertext.length != kHybridCiphertextBytes) {
      return;
    }
    final List<int> bytes;
    try {
      bytes = base64Url.decode(base64Url.normalize(sealed));
    } on FormatException {
      return;
    }
    if (bytes.length < 12 + 16) {
      return;
    }
    final Uint8List secret = await hybridKem.decapsulate(
      seed,
      ciphertext,
      info: _kemInfo(s.id),
    );
    final List<int> shared = _sharedKey(
      secret,
      sid: s.id,
      helloPublic: await hybridKem.publicKeyOf(seed),
      ciphertext: ciphertext,
    );
    secret.fillRange(0, secret.length, 0);
    final List<int> plain;
    try {
      plain = await _aead.decrypt(
        cg.SecretBox(
          bytes.sublist(12, bytes.length - 16),
          nonce: bytes.sublist(0, 12),
          mac: cg.Mac(bytes.sublist(bytes.length - 16)),
        ),
        secretKey: cg.SecretKey(shared),
        aad: _replyAad(s.id),
      );
    } on cg.SecretBoxAuthenticationError {
      return; // not for this phone
    }
    final Object? body = jsonDecode(utf8.decode(plain));
    if (body is! Map) {
      return;
    }
    final Object? address = body['a'];
    final Object? text = body['m'];
    if (address is! String ||
        !isRoutablePeerAddress(address) ||
        text is! String ||
        _isBlocked(address) ||
        s.address != null ||
        !identical(_sessions[s.id], s)) {
      return;
    }
    // The one-time key has done its work: gone from memory.
    seed.fillRange(0, seed.length, 0);
    s
      ..address = PeerShareCodec.normalizeAddress(address)
      .._shared = shared
      .._helloSeed = null
      ..lines.add(
        NearbyLine(false, _clip(text, kNearbyHelloMaxLength), _now()),
      );
    notifyListeners();
  }

  /// Makes room for a new conversation: the oldest one someone nearby
  /// started that this person never answered goes. `false` when there is
  /// none (every conversation is one this person took part in).
  bool _dropOldSession() {
    for (final NearbySession x in _sessions.values) {
      if (!x.startedByMe && !x.iAnswered) {
        _sessions.remove(x.id);
        return true;
      }
    }
    return false;
  }

  /// Answers / writes in a nearby conversation. The first answer to a hello
  /// without an address goes over Bluetooth (and needs that phone nearby).
  Future<bool> send(NearbySession s, String text) async {
    final String message = text.trim();
    if (!s.canSend || message.isEmpty) {
      return false;
    }
    final String? address = s.address;
    if (address == null) {
      final String answer = _clip(message, kNearbyReplyMaxLength);
      if (!await _answerOverAir(s, answer)) {
        return false;
      }
      s.lines.add(NearbyLine(true, answer, _now()));
      notifyListeners();
      return true;
    }
    final List<int>? shared = s._shared;
    await sendMesh(address, <String, dynamic>{
      'type': kNearbyMessageType,
      'sid': s.id,
      'n': myPseudonym,
      'm': message,
      if (shared != null && s.startedByMe) 'pf': _bindProof(shared, s.id),
    });
    s.lines.add(NearbyLine(true, message, _now()));
    notifyListeners();
    return true;
  }

  void _onFrame(SignalTransportFrame frame) {
    if (frame.payload['type'] != kNearbyMessageType) {
      return;
    }
    final Object? id = frame.payload['sid'];
    final Object? text = frame.payload['m'];
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    final NearbySession? s = id is String ? _sessions[id] : null;
    if (s == null || text is! String || _isBlocked(from)) {
      return;
    }
    final String? had = s.address;
    if (had == null) {
      if (s.startedByMe) {
        // The answer to a hello without an address comes over Bluetooth.
        return;
      } else {
        // The hello's author writes first after this person answered: the
        // proof shows they hold the hello's key.
        final List<int>? shared = s._shared;
        final Object? proof = frame.payload['pf'];
        if (shared == null ||
            proof is! String ||
            proof != _bindProof(shared, s.id)) {
          return;
        }
        s.address = from;
      }
    } else if (had != from) {
      return;
    }
    // One message from a stranger until this person answers: kept here,
    // not only by the sender's app.
    if (!s.startedByMe && !s.iAnswered) {
      return;
    }
    s.lines.add(NearbyLine(false, _clip(text, 2000), _now()));
    if (s.lines.length > 500) {
      s.lines.removeAt(0);
    }
    notifyListeners();
  }

  /// Blocks the other side of [s] for good (its address, kept in the
  /// book), or — before they gave one — their phone's token for now.
  void block(NearbySession s) {
    final String? a = s.address;
    if (a != null) {
      final String key = PeerShareCodec.normalizeAddress(a);
      _blockedNow.add(key);
      _sessions.removeWhere((String _, NearbySession x) => x.address == key);
      unawaitedLogged(meet.blockNearby(key), context: 'W pobliżu: blokada');
    }
    if (s.peerToken.isNotEmpty) {
      _blockedTokens.add(s.peerToken);
    }
    _sessions.remove(s.id);
    notifyListeners();
  }

  /// How many addresses are blocked nearby.
  int get blockedCount =>
      <String>{..._blockedNow, ...meet.book.nearbyBlocked}.length;

  /// Lets everyone blocked nearby write again.
  Future<void> unblockAll() async {
    _blockedNow.clear();
    _blockedTokens.clear();
    await meet.unblockNearby();
    notifyListeners();
  }

  Future<void> close() async {
    _tick?.cancel();
    _networkTimer?.cancel();
    _networkTimer = null;
    _networkLook = false;
    network?.update(firstSlot: 0, adverts: null, looking: false);
    for (final StreamSubscription<Object?> sub in _subs) {
      await sub.cancel();
    }
    await radio.stopScan();
    await radio.stopAdvertising();
  }
}
