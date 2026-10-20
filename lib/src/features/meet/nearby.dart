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
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby_crypto.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

export 'package:zen/src/features/meet/nearby_crypto.dart';

/// Mesh payload of a conversation started nearby.
const String kNearbyMessageType = 'nearby_msg';

/// Hello of 1.10.0 phones: it carries the sender's mesh address. Still read,
/// and sent only to phones that show a 1.10.0 token (transition; the screen
/// says so before sending).
const int kNearbyLegacyHelloVersion = 1;

/// Hello without any address (S5): the pseudonym, the message, the
/// sender's token and a one-time X25519 key. Nobody learns an address until
/// the other person answers.
const int kNearbyHelloVersion = 7;

/// The answer to a [kNearbyHelloVersion] hello, over Bluetooth: the
/// answering person's mesh address, pseudonym and message, sealed for the
/// hello's one-time key (only that phone can open it).
const int kNearbyReplyVersion = 8;

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

/// The Bluetooth radio (native in the app, a fake in tests).
abstract interface class NearbyRadio {
  Stream<Map<Object?, Object?>> get events;
  Future<Map<Object?, Object?>> state();
  Future<bool> requestPermissions();

  /// Asks the person to switch Bluetooth on (the system dialog). Returns
  /// whether it is on already; a change comes later as a `bluetooth` event.
  Future<bool> requestEnable();
  Future<bool> startAdvertising(Uint8List token);
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
  /// `p:…`, or a 1.10.0 friend's legacy secret): the radio side checks an
  /// alarm wave's signature with them before counting it, so a flood of
  /// other waves cannot crowd a friend's alarm out (§16.3).
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
    this.modern = false,
  });

  final String token;
  String device;
  int rssi;
  int seenAt;

  /// A friend's address when the token is theirs.
  final String? friend;

  /// The phone shows a token with a hint (a version newer than 1.10.0): it
  /// understands hellos without an address.
  bool modern;

  String get pseudonym => nearbyPseudonym(_unhex(token));
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
    this.legacy = false,
    this.peerToken = '',
  });

  final String id;
  String pseudonym;

  /// Their mesh address (known once they answered, or from a 1.10.0 hello).
  String? address;
  final bool startedByMe;

  /// A 1.10.0 hello: the address went with the hello itself.
  final bool legacy;

  /// The other phone's token when the conversation started (badges).
  final String peerToken;
  final List<NearbyLine> lines = <NearbyLine>[];

  /// The one-time key of this phone's hello (memory only).
  cg.SimpleKeyPair? _helloKeys;

  /// The one-time key of their hello (memory only).
  List<int>? _peerPublic;

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
    return !legacy && _peerPublic != null && !iAnswered;
  }

  /// This person answered a hello without an address and waits for its
  /// author to write over the network.
  bool get waitsForThem => !startedByMe && address == null && iAnswered;
}

/// "Osoby w pobliżu" (§15): shows this phone to people around (friends
/// recognise it, strangers see a changing pseudonym), lists who is near,
/// marks friends met in person, and lets strangers say hello.
final class NearbyService extends ChangeNotifier {
  NearbyService({
    required this.radio,
    required this.meet,
    required this.ownAddress,
    required this.sendMesh,
    required Stream<SignalTransportFrame> frames,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure() {
    _subs
      ..add(radio.events.listen(_onRadio))
      ..add(frames.listen(_onFrame));
  }

  final NearbyRadio radio;
  final MeetService meet;
  final String Function() ownAddress;
  final Future<void> Function(String to, Map<String, dynamic> payload) sendMesh;
  final int Function() _now;
  final Random _random;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  static final cg.X25519 _x25519 = cg.X25519();
  static final cg.Chacha20 _aead = cg.Chacha20.poly1305Aead();

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
  Map<String, String> _legacyTokens = <String, String>{};
  Map<String, List<(String, int)>> _hints = <String, List<(String, int)>>{};
  Map<String, String> _pairIds = <String, String>{};
  int _keysEpoch = -1;
  int _keysSlot = -1;

  /// Per friend: the last checked chain value (its slot), so the next
  /// check is a few hashes.
  final Map<String, (int, List<int>)> _checked = <String, (int, List<int>)>{};

  /// Tokens recognised as a friend's (token → friend, slot).
  final Map<String, (String, int)> _recognised = <String, (String, int)>{};

  NearbyOwnKeys? _own;
  String? _ownFrom;

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

  /// Waves of other kinds (a flat's invitation §18.3, a crisis
  /// announcement §28.1): each handler picks its own version.
  final List<void Function(Map<dynamic, dynamic> json)> otherWaveHandlers =
      <void Function(Map<dynamic, dynamic> json)>[];

  /// Alarm waves ([kAlarmWaveVersion], [kAlarmPairWaveVersion], §16.3) with
  /// the Bluetooth address of the phone that wrote them (for limits on what
  /// strangers send).
  final List<void Function(Map<dynamic, dynamic> json, String device)>
  alarmWaveHandlers =
      <void Function(Map<dynamic, dynamic> json, String device)>[];

  /// Bluetooth was switched on (`true`) or off on this phone.
  final List<void Function(bool on)> bluetoothHandlers =
      <void Function(bool on)>[];
  Timer? _tick;

  /// Seen within this long counts as "here".
  static const Duration fresh = Duration(minutes: 2);

  /// A friend this close counts as met in person.
  static const int metRssi = -80;

  /// Conversations started by people nearby kept at most, and per address
  /// (or token) they came from (a wave is free to send, so a phone nearby
  /// could otherwise fill the list without end). Of those, one at a time
  /// may wait for this person's answer (§15: one message from a stranger
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
    return keys == null ? '' : _hex(keys.token(nearbySlot(_now())));
  }

  String get myPseudonym {
    final String token = myToken;
    return token.isEmpty ? t('Ktoś obok') : nearbyPseudonym(_unhex(token));
  }

  /// Reads the friends' keys again when the slot (or the legacy epoch)
  /// changed, or always with [force].
  void _refreshFriendKeys({bool force = false}) {
    final int now = _now();
    final int epoch = nearbyEpoch(now);
    final int slot = nearbySlot(now);
    if (!force && epoch == _keysEpoch && slot == _keysSlot) {
      return;
    }
    _keysEpoch = epoch;
    _keysSlot = slot;
    final Map<String, String> stored = Map<String, String>.of(
      meet.book.friendNearbySecrets,
    );
    final Map<String, FriendNearbyKey> keys = <String, FriendNearbyKey>{};
    final Map<String, String> legacy = <String, String>{};
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
      final List<int>? mask = key.mask;
      final List<int>? pair = key.pair;
      if (mask == null || pair == null) {
        // A 1.10.0 friend (transition): their legacy tokens.
        for (final int ep in <int>[epoch - 1, epoch, epoch + 1]) {
          try {
            legacy[_hex(nearbyToken(key.legacy!, ep))] = friend;
          } on FormatException {
            // a damaged secret: nothing to match
          }
        }
        continue;
      }
      for (int s = slot - 1; s <= slot + 1; s++) {
        (hints[_hex(nearbyHint(mask, s))] ??= <(String, int)>[]).add((
          friend,
          s,
        ));
      }
      for (int s = slot - 2; s <= slot + 2; s++) {
        pairIds[nearbyPairId(pair, s)] = friend;
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
    _legacyTokens = legacy;
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
  /// which gives the phone a new Bluetooth address with it (S6).
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
    final bool ok = await radio.startAdvertising(keys.advert(slot));
    _advertisedSlot = ok ? slot : -1;
    return ok;
  }

  Future<bool> startScanning({bool lowPower = false}) async {
    // Whoever asks now owns the scan: a short look around running
    // meanwhile no longer ends it.
    _windowOpen = false;
    return _startScan(lowPower: lowPower);
  }

  Future<bool> _startScan({required bool lowPower}) async {
    friendsChanged();
    scanning = await radio.startScan(lowPower: lowPower);
    _syncTimer();
    notifyListeners();
    return scanning;
  }

  Future<void> stopScanning() async {
    _windowOpen = false;
    scanning = false;
    await radio.stopScan();
    _syncTimer();
    notifyListeners();
  }

  /// One short, low-power look around (§15: without the "W pobliżu" screen
  /// the phone only peeks now and then, to save the battery). Friends in
  /// range are marked met in person as usual. Skipped while something else
  /// is scanning; whoever starts scanning meanwhile takes the scan over.
  /// Returns whether it ran.
  Future<bool> scanWindow(Duration length) async {
    if (scanning) {
      return false;
    }
    _windowOpen = true;
    if (!await _startScan(lowPower: true)) {
      _windowOpen = false;
      return false;
    }
    await Future<void>.delayed(length);
    if (_windowOpen) {
      await stopScanning();
    }
    return true;
  }

  void _syncTimer() {
    if (!visible && !scanning) {
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
        _seen(token.sublist(0, 16), h, device, rssi);
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

  /// A Zen phone nearby showed [raw] (16 bytes) with [hint] (newer phones).
  void _seen(List<int> raw, List<int>? hint, String device, int rssi) {
    final String token = _hex(raw);
    if (token == myToken) {
      return;
    }
    _refreshFriendKeys();
    final String? friend =
        _legacyTokens[token] ??
        (hint == null ? null : _recognise(raw, _hex(hint), token));
    final int t = _now();
    final NearbyPerson? had = _people[token];
    if (had != null) {
      had
        ..device = device
        ..rssi = rssi
        ..seenAt = t
        ..modern = hint != null;
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
        device: device,
        rssi: rssi,
        seenAt: t,
        friend: friend,
        modern: hint != null,
      );
    }
    if (friend != null && rssi >= metRssi && meet.book.metAt(friend) == null) {
      unawaitedLogged(meet.markMet(friend), context: 'Spotkani osobiście');
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
  /// and [text] — no account and no address (S5); the address goes only to
  /// someone who answers ([kNearbyReplyVersion]). A 1.10.0 phone
  /// ([NearbyPerson.modern] false) understands only the old hello, which
  /// carries the mesh address (the screen says so first).
  Future<NearbySession?> wave(NearbyPerson person, String text) async {
    final String message = _clip(text.trim(), kNearbyHelloMaxLength);
    if (ownAddress().isEmpty || message.isEmpty) {
      return null;
    }
    await meet.nearbyPrivateKey();
    final String id = _newId();
    cg.SimpleKeyPair? keys;
    final Map<String, dynamic> json;
    if (person.modern) {
      keys = await _x25519.newKeyPair();
      final cg.SimplePublicKey publicKey = await keys.extractPublicKey();
      json = <String, dynamic>{
        'v': kNearbyHelloVersion,
        'sid': id,
        'n': myPseudonym,
        't': myToken,
        'e': base64Url.encode(publicKey.bytes),
        'm': message,
      };
    } else {
      // Transition: a 1.10.0 phone reads only this one.
      json = <String, dynamic>{
        'v': kNearbyLegacyHelloVersion,
        'sid': id,
        'n': myPseudonym,
        'a': ownAddress(),
        'm': message,
      };
    }
    if (!await radio.wave(person.device, _encode(json))) {
      return null;
    }
    final NearbySession s =
        NearbySession(
            id: id,
            pseudonym: person.pseudonym,
            startedByMe: true,
            legacy: !person.modern,
            peerToken: person.token,
          )
          .._helloKeys = keys
          ..lines.add(NearbyLine(true, message, _now()));
    _sessions[id] = s;
    notifyListeners();
    return s;
  }

  /// Sends [json] over Bluetooth to every phone around right now ([only]:
  /// to those it picks). Returns how many got it.
  ///
  /// An alarm wave ([kAlarmWaveVersion], signed for everyone) goes to a
  /// friend who gave per-friend keys signed with the key of that pair
  /// instead ([kAlarmPairWaveVersion]): only they can check it.
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
      if (only != null && !only(p)) {
        continue;
      }
      Uint8List out = data;
      final String? friend = p.friend;
      if (alarm != null &&
          own != null &&
          friend != null &&
          (_friendKeys[friend]?.paired ?? false)) {
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
  /// again (an alarm told to phones nearby, §16.3).
  Future<int> waveAround(
    Map<String, dynamic> json, {
    Duration listen = const Duration(seconds: 6),
    bool Function(NearbyPerson person)? only,
  }) async {
    // A short look around does not count: it would end halfway through.
    final bool wasScanning = scanning && !_windowOpen;
    if (!wasScanning) {
      if (!await startScanning(lowPower: false)) {
        return 0;
      }
      await Future<void>.delayed(listen);
    }
    try {
      return await waveAll(json, only: only);
    } finally {
      if (!wasScanning) {
        await stopScanning();
      }
    }
  }

  /// The friend whose alarm-wave token [token] (hex) is — a pair's id, or a
  /// 1.10.0 friend's legacy token — or `null` for a stranger.
  String? friendOfToken(Object? token) {
    if (token is! String || token.isEmpty) {
      return null;
    }
    _refreshFriendKeys();
    return _pairIds[token] ?? _legacyTokens[token];
  }

  /// [device]: the Bluetooth address of the phone that wrote it.
  /// [alarmsElsewhere]: another part of the app (the Android background
  /// service, or the app itself) answers alarm waves right now, so they are
  /// not handed on here — the alarm rings once (§16.3).
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
      if (v == kAlarmWaveVersion || v == kAlarmPairWaveVersion) {
        if (alarmsElsewhere) {
          return;
        }
        for (final void Function(Map<dynamic, dynamic>, String) h
            in alarmWaveHandlers.toList()) {
          h(json, device);
        }
        return;
      }
      if (v == kNearbyLegacyHelloVersion) {
        _onLegacyHello(json);
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

  /// A 1.10.0 hello (transition): it carries the sender's mesh address.
  void _onLegacyHello(Map<dynamic, dynamic> json) {
    final Object? id = json['sid'];
    final Object? name = json['n'];
    final Object? address = json['a'];
    final Object? text = json['m'];
    if (id is! String ||
        id.length > 40 ||
        name is! String ||
        address is! String ||
        !isRoutablePeerAddress(address) ||
        text is! String ||
        _isBlocked(address) ||
        _sessions.containsKey(id)) {
      return;
    }
    // The address is the sender's own word (Bluetooth carries no proof):
    // an answer goes there, nothing else is done with it.
    final String from = PeerShareCodec.normalizeAddress(address);
    if (!_roomFor((NearbySession x) => x.address == from)) {
      return;
    }
    _sessions[id] = NearbySession(
      id: id,
      pseudonym: _clip(name, 40),
      address: from,
      legacy: true,
    )..lines.add(NearbyLine(false, _clip(text, kNearbyHelloMaxLength), _now()));
    notifyListeners();
  }

  static final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');

  static List<int>? _key32(Object? b64) {
    if (b64 is! String || b64.length > 64) {
      return null;
    }
    try {
      final List<int> bytes = base64Url.decode(base64Url.normalize(b64));
      return bytes.length == 32 ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  /// A hello without an address ([kNearbyHelloVersion]).
  void _onHello(Map<dynamic, dynamic> json) {
    final Object? id = json['sid'];
    final Object? name = json['n'];
    final Object? token = json['t'];
    final Object? text = json['m'];
    final List<int>? publicKey = _key32(json['e']);
    if (id is! String ||
        !kAlarmIdPattern.hasMatch(id) ||
        name is! String ||
        token is! String ||
        !_hex32.hasMatch(token) ||
        text is! String ||
        publicKey == null ||
        _blockedTokens.contains(token) ||
        _sessions.containsKey(id)) {
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

  /// The key of a hello and its answer: X25519 of the two one-time keys,
  /// bound to the conversation and both public keys.
  static Future<List<int>> _sharedKey(
    cg.SimpleKeyPair mine,
    List<int> theirs, {
    required String sid,
    required List<int> helloPublic,
    required List<int> replyPublic,
  }) async {
    final cg.SecretKey shared = await _x25519.sharedSecretKey(
      keyPair: mine,
      remotePublicKey: cg.SimplePublicKey(theirs, type: cg.KeyPairType.x25519),
    );
    return crypto.sha256.convert(<int>[
      ...utf8.encode('zen-nearby-hello|$sid|'),
      ...await shared.extractBytes(),
      ...helloPublic,
      ...replyPublic,
    ]).bytes;
  }

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
    final List<int>? theirs = s._peerPublic;
    final String address = ownAddress();
    if (theirs == null || address.isEmpty) {
      return false;
    }
    final cg.SimpleKeyPair keys = await _x25519.newKeyPair();
    final List<int> mine = (await keys.extractPublicKey()).bytes;
    final List<int> shared = await _sharedKey(
      keys,
      theirs,
      sid: s.id,
      helloPublic: theirs,
      replyPublic: mine,
    );
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
    final int sent = await waveAround(
      <String, dynamic>{
        'v': kNearbyReplyVersion,
        'sid': s.id,
        'e': base64Url.encode(mine),
        'c': base64Url.encode(<int>[
          ...nonce,
          ...box.cipherText,
          ...box.mac.bytes,
        ]),
      },
      listen: replyListen,
      only: (NearbyPerson p) => p.modern,
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
    final List<int>? theirs = _key32(json['e']);
    final NearbySession? s = id is String ? _sessions[id] : null;
    final cg.SimpleKeyPair? keys = s?._helloKeys;
    if (s == null ||
        keys == null ||
        !s.startedByMe ||
        s.address != null ||
        theirs == null ||
        sealed is! String ||
        sealed.length > 2048) {
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
    final List<int> mine = (await keys.extractPublicKey()).bytes;
    final List<int> shared = await _sharedKey(
      keys,
      theirs,
      sid: s.id,
      helloPublic: mine,
      replyPublic: theirs,
    );
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
    s
      ..address = PeerShareCodec.normalizeAddress(address)
      .._shared = shared
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
        if (!s.legacy) {
          return;
        }
        s.address = from;
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
    for (final StreamSubscription<Object?> sub in _subs) {
      await sub.cancel();
    }
    await radio.stopScan();
    await radio.stopAdvertising();
  }
}
