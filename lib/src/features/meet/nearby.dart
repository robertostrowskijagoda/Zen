import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
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

  /// Friends' nearby secrets: the radio side checks an alarm wave's
  /// signature with them before counting it, so a flood of other waves
  /// cannot crowd a friend's alarm out (§16.3).
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
  });

  final String token;
  String device;
  int rssi;
  int seenAt;

  /// A friend's address when the token is theirs.
  final String? friend;

  String get pseudonym => nearbyPseudonym(_unhex(token));
}

List<int> _unhex(String hex) => <int>[
  for (int i = 0; i + 1 < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

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
  });

  final String id;
  String pseudonym;

  /// Their mesh address (known once they wrote or answered).
  String? address;
  final bool startedByMe;
  final List<NearbyLine> lines = <NearbyLine>[];

  /// One message to a stranger until they answer.
  bool get canSend =>
      address != null && (!startedByMe || lines.any((NearbyLine l) => !l.mine));
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

  final Map<String, NearbyPerson> _people = <String, NearbyPerson>{};
  final Map<String, NearbySession> _sessions = <String, NearbySession>{};
  final Set<String> _blocked = <String>{};
  Map<String, String> _friendTokens = <String, String>{};
  int _tokensEpoch = -1;

  /// The friends' secrets last handed to the radio ([_pushAlarmKeys]).
  String? _alarmKeysGiven;
  int _advertisedEpoch = -1;
  bool visible = false;
  bool scanning = false;

  /// The scan running now is only a short look around ([scanWindow]).
  bool _windowOpen = false;

  /// Waves of other kinds (a flat's invitation §18.3, a crisis
  /// announcement §28.1): each handler picks its own version.
  final List<void Function(Map<dynamic, dynamic> json)> otherWaveHandlers =
      <void Function(Map<dynamic, dynamic> json)>[];

  /// Alarm waves ([kAlarmWaveVersion], §16.3) with the Bluetooth address
  /// of the phone that wrote them (for limits on what strangers send).
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
  /// they gave (a wave is free to send, so a phone nearby could otherwise
  /// fill the list without end).
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

  String get myToken {
    final String? secret = meet.book.nearbySecret;
    return secret == null ? '' : _hex(nearbyToken(secret, nearbyEpoch(_now())));
  }

  String get myPseudonym {
    final String token = myToken;
    return token.isEmpty ? t('Ktoś obok') : nearbyPseudonym(_unhex(token));
  }

  void _refreshFriendTokens() {
    final int epoch = nearbyEpoch(_now());
    if (epoch == _tokensEpoch) {
      return;
    }
    _tokensEpoch = epoch;
    final Map<String, String> map = <String, String>{};
    meet.book.friendNearbySecrets.forEach((String friend, String secret) {
      for (final int e in <int>[epoch - 1, epoch, epoch + 1]) {
        try {
          map[_hex(nearbyToken(secret, e))] = friend;
        } on FormatException {
          // a damaged secret: nothing to match
        }
      }
    });
    _friendTokens = map;
    _pushAlarmKeys();
  }

  /// Hands friends' nearby secrets to the native radio (when they changed),
  /// which checks a friend's signed alarm wave before its limits for
  /// strangers apply.
  void _pushAlarmKeys() {
    final NearbyRadio r = radio;
    if (r is! ChannelNearbyRadio) {
      return;
    }
    final List<String> secrets =
        meet.book.friendNearbySecrets.values.toSet().toList()..sort();
    final String given = secrets.join('\n');
    if (given == _alarmKeysGiven) {
      return;
    }
    _alarmKeysGiven = given;
    unawaitedLogged(
      r.setAlarmKeys(secrets),
      context: 'W pobliżu: klucze alarmu',
    );
  }

  /// Friends' secrets changed (a new friend, a renewed secret).
  void friendsChanged() {
    _tokensEpoch = -1;
    _refreshFriendTokens();
  }

  /// Shows this phone to people nearby (and keeps the token fresh).
  Future<bool> setVisible(bool on) async {
    visible = on;
    if (!on) {
      _advertisedEpoch = -1;
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

  Future<bool> _advertise({bool force = false}) async {
    final int epoch = nearbyEpoch(_now());
    if (!force && epoch == _advertisedEpoch) {
      return true;
    }
    final String secret = await meet.nearbySecret();
    final bool ok = await radio.startAdvertising(nearbyToken(secret, epoch));
    _advertisedEpoch = ok ? epoch : -1;
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
      _refreshFriendTokens();
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
        final Object? device = event['device'];
        final Object? rssi = event['rssi'];
        if (token is! List<int> || device is! String || rssi is! int) {
          return;
        }
        _seen(_hex(token), device, rssi);
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
          _advertisedEpoch = -1;
        }
        for (final void Function(bool) h in bluetoothHandlers.toList()) {
          h(on);
        }
        notifyListeners();
    }
  }

  /// A Zen phone nearby showed [token].
  void _seen(String token, String device, int rssi) {
    if (token == myToken) {
      return;
    }
    _refreshFriendTokens();
    final String? friend = _friendTokens[token];
    final int t = _now();
    final NearbyPerson? had = _people[token];
    if (had != null) {
      had
        ..device = device
        ..rssi = rssi
        ..seenAt = t;
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
      );
    }
    if (friend != null && rssi >= metRssi && meet.book.metAt(friend) == null) {
      unawaitedLogged(meet.markMet(friend), context: 'Spotkani osobiście');
    }
    notifyListeners();
  }

  // ---- talking to strangers ----

  String _newId() => List<String>.generate(
    12,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  /// Says hello to [person] over Bluetooth: they get this phone's pseudonym,
  /// [text] and the mesh address to answer to — not the account.
  Future<NearbySession?> wave(NearbyPerson person, String text) async {
    final String address = ownAddress();
    if (address.isEmpty || text.trim().isEmpty) {
      return null;
    }
    await meet.nearbySecret();
    final String id = _newId();
    final Uint8List data = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'v': 1,
          'sid': id,
          'n': myPseudonym,
          'a': address,
          'm': text.trim().length > 300
              ? text.trim().substring(0, 300)
              : text.trim(),
        }),
      ),
    );
    if (!await radio.wave(person.device, data)) {
      return null;
    }
    final NearbySession s = NearbySession(
      id: id,
      pseudonym: person.pseudonym,
      startedByMe: true,
    )..lines.add(NearbyLine(true, text.trim(), _now()));
    _sessions[id] = s;
    notifyListeners();
    return s;
  }

  /// Sends [json] over Bluetooth to every phone around right now. Returns
  /// how many got it.
  Future<int> waveAll(Map<String, dynamic> json) async {
    final Uint8List data = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    int sent = 0;
    for (final NearbyPerson p in people) {
      if (await radio.wave(p.device, data)) {
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
      return await waveAll(json);
    } finally {
      if (!wasScanning) {
        await stopScanning();
      }
    }
  }

  /// The friend whose nearby token [token] (hex) is, or `null` for a
  /// stranger.
  String? friendOfToken(Object? token) {
    if (token is! String || token.isEmpty) {
      return null;
    }
    _refreshFriendTokens();
    return _friendTokens[token];
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
      if (json['v'] == kAlarmWaveVersion) {
        if (alarmsElsewhere) {
          return;
        }
        for (final void Function(Map<dynamic, dynamic>, String) h
            in alarmWaveHandlers.toList()) {
          h(json, device);
        }
        return;
      }
      if (json['v'] != 1) {
        for (final void Function(Map<dynamic, dynamic>) h
            in otherWaveHandlers) {
          h(json);
        }
        return;
      }
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
          _blocked.contains(PeerShareCodec.normalizeAddress(address)) ||
          _sessions.containsKey(id)) {
        return;
      }
      // The address is the sender's own word (Bluetooth carries no proof):
      // an answer goes there, nothing else is done with it.
      final String from = PeerShareCodec.normalizeAddress(address);
      if (_sessions.values
              .where((NearbySession x) => !x.startedByMe && x.address == from)
              .length >=
          maxSessionsPerAddress) {
        return;
      }
      if (_sessions.length >= maxSessions && !_dropOldSession()) {
        return;
      }
      final NearbySession s =
          NearbySession(
              id: id,
              pseudonym: name.length > 40 ? name.substring(0, 40) : name,
              address: from,
            )
            ..lines.add(
              NearbyLine(
                false,
                text.length > 300 ? text.substring(0, 300) : text,
                _now(),
              ),
            );
      _sessions[id] = s;
      notifyListeners();
    } on Object catch (error) {
      logZenWarning('W pobliżu: niezrozumiałe przywitanie: $error');
    }
  }

  /// Makes room for a new conversation: the oldest one someone nearby
  /// started that this person never answered goes. `false` when there is
  /// none (every conversation is one this person took part in).
  bool _dropOldSession() {
    for (final NearbySession x in _sessions.values) {
      if (!x.startedByMe && !x.lines.any((NearbyLine l) => l.mine)) {
        _sessions.remove(x.id);
        return true;
      }
    }
    return false;
  }

  /// Answers / writes in a nearby conversation.
  Future<bool> send(NearbySession s, String text) async {
    final String? address = s.address;
    if (address == null || !s.canSend || text.trim().isEmpty) {
      return false;
    }
    await sendMesh(address, <String, dynamic>{
      'type': kNearbyMessageType,
      'sid': s.id,
      'n': myPseudonym,
      'm': text.trim(),
    });
    s.lines.add(NearbyLine(true, text.trim(), _now()));
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
    if (s == null || text is! String || _blocked.contains(from)) {
      return;
    }
    if (s.address == null && s.startedByMe) {
      s.address = from;
    } else if (s.address != from) {
      return;
    }
    s.lines.add(
      NearbyLine(
        false,
        text.length > 2000 ? text.substring(0, 2000) : text,
        _now(),
      ),
    );
    if (s.lines.length > 500) {
      s.lines.removeAt(0);
    }
    notifyListeners();
  }

  void block(NearbySession s) {
    final String? a = s.address;
    if (a != null) {
      _blocked.add(a);
    }
    _sessions.remove(s.id);
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
