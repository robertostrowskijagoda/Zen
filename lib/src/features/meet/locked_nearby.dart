import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/nearby_keeper.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// "People nearby" while the app is locked or closed: the Android background
// service has no master key, so the app leaves it a nearby kit, sealed with
// the background key like the alarm kit. It holds no key of this person:
//  - the tokens this phone shows, worked out in advance for the next days
//    (not the private nearby key: whoever opened the kit could show this
//    phone for those days at most, never later, and could not sign alarm
//    waves in this person's name). The radio side changes them at every
//    slot by itself, so nothing wakes up for it;
//  - what friends gave this phone to recognise them (their mask key,
//    anchors and the pair key their alarm waves are signed with);
//  - the settings.
// What the service sees goes into the sealed inbox; the app merges it after
// unlock.

/// How many days of tokens the kit holds, from the start of the day it was
/// written: at least a week, it is written again every day the app is
/// unlocked.
const int kNearbyKitDays = 8;

/// Friends' keys the kit holds at most.
const int kNearbyKitMaxFriends = 1000;

/// Slots in a day.
final int _slotsPerDay =
    Duration.millisecondsPerDay ~/ kNearbySlot.inMilliseconds;

/// What the locked service shows and recognises nearby.
@immutable
final class NearbyKit {
  const NearbyKit({
    required this.createdAt,
    required this.self,
    this.visible = false,
    this.alarms = false,
    this.look = false,
    this.record = false,
    this.friends = const <String, String>{},
    this.firstSlot = 0,
    this.adverts,
  });

  final int createdAt;

  /// This device's address (what the service's records come from).
  final String self;

  /// Show this phone ([MeetBook.nearbyVisible]).
  final bool visible;

  /// Take friends' alarm waves ([MeetBook.alarmNearby], only while shown:
  /// phones around wave only at phones they see).
  final bool alarms;

  /// Look around every few minutes ([MeetBook.nearbyBackgroundScan]).
  final bool look;

  /// Write down who was passed ("Zapisuj, kogo mijam").
  final bool record;

  /// Friend (normalised address) → what they gave this phone
  /// ([FriendNearbyKey]).
  final Map<String, String> friends;

  /// The slot of the first of [adverts].
  final int firstSlot;

  /// What the radio shows, [kNearbyAdvertBytes] per slot from [firstSlot]
  /// on (`null`: not shown).
  final Uint8List? adverts;

  int get advertCount => (adverts?.length ?? 0) ~/ kNearbyAdvertBytes;

  /// Whether [adverts] hold the token of [slot].
  bool covers(int slot) => slot >= firstSlot && slot < firstSlot + advertCount;

  /// What the radio shows in [slot]; `null` outside [adverts].
  Uint8List? advertAt(int slot) {
    final Uint8List? all = adverts;
    if (all == null || !covers(slot)) {
      return null;
    }
    final int at = (slot - firstSlot) * kNearbyAdvertBytes;
    return Uint8List.sublistView(all, at, at + kNearbyAdvertBytes);
  }

  static const int version = 1;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': version,
    't': createdAt,
    'me': self,
    if (visible) 'vis': true,
    if (alarms) 'al': true,
    if (look) 'lk': true,
    if (record) 'rec': true,
    'f': friends,
    if (adverts case final Uint8List a) ...<String, dynamic>{
      's': firstSlot,
      'a': base64Url.encode(a),
    },
  };

  static NearbyKit? fromJson(Object? json) {
    if (json is! Map || json['v'] != version) {
      return null;
    }
    final Object? t = json['t'];
    final Object? me = json['me'];
    final Object? f = json['f'];
    final Object? s = json['s'];
    final Object? a = json['a'];
    if (t is! int || me is! String || me.isEmpty) {
      return null;
    }
    Uint8List? adverts;
    int firstSlot = 0;
    if (s is int && a is String) {
      try {
        final Uint8List bytes = base64Url.decode(base64Url.normalize(a));
        if (bytes.isNotEmpty && bytes.length % kNearbyAdvertBytes == 0) {
          adverts = bytes;
          firstSlot = s;
        }
      } on FormatException {
        adverts = null;
      }
    }
    return NearbyKit(
      createdAt: t,
      self: me,
      visible: json['vis'] == true && adverts != null,
      alarms: json['al'] == true,
      look: json['lk'] == true,
      record: json['rec'] == true,
      friends: <String, String>{
        if (f is Map)
          for (final MapEntry<dynamic, dynamic> e in f.entries.take(
            kNearbyKitMaxFriends,
          ))
            if (e.key is String &&
                e.value is String &&
                FriendNearbyKey.parse(e.value as String) != null)
              e.key as String: e.value as String,
      },
      firstSlot: firstSlot,
      adverts: adverts,
    );
  }
}

/// Where the nearby kit is kept.
BackgroundKitFile nearbyKitFile({
  required Future<Directory> Function() supportDirectory,
  required AppSecurityCredentialsStore credentials,
  bool createKey = false,
}) => BackgroundKitFile(
  supportDirectory: supportDirectory,
  credentials: credentials,
  storageKey: 'background/nearby-kit',
  fileName: 'nearby-kit.zenbg',
  createKey: createKey,
);

/// The adverts of [args] (private key, first slot, count), worked out in
/// an isolate of their own (a few thousand hashes).
Uint8List _advertsFor((String, int, int) args) =>
    NearbyOwnKeys(args.$1).adverts(args.$2, args.$3);

/// Keeps the nearby kit in step while the app is unlocked: [refresh] writes
/// it again when what it holds changed (the settings, friends' keys, this
/// phone's key) or a new day began (the tokens move on with it).
final class NearbyKitKeeper {
  NearbyKitKeeper({
    required this.meet,
    required this.write,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final MeetService meet;
  final Future<void> Function(NearbyKit kit) write;
  final int Function() _now;

  String? _written;
  Future<void> _queue = Future<void>.value();

  /// How many times the kit was written (tests, logs).
  int get writes => _writes;
  int _writes = 0;

  /// Writes the kit when it changed. [recording]: "Zapisuj, kogo mijam".
  /// Returns whether it wrote.
  Future<bool> refresh({required bool recording}) {
    final Completer<bool> done = Completer<bool>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await _refresh(recording));
      } on Object catch (error, stackTrace) {
        logZenError('Writing the nearby kit failed', error, stackTrace);
        done.complete(false);
      }
    });
    return done.future;
  }

  Future<bool> _refresh(bool recording) async {
    final String self = PeerShareCodec.normalizeAddress(
      meet.ownAddress?.call() ?? '',
    );
    if (self.isEmpty) {
      return false;
    }
    final MeetBook book = meet.book;
    final bool visible = book.nearbyVisible;
    final List<String> addresses =
        book.friendNearbySecrets.keys
            .where(meet.host.isFriend)
            .map(PeerShareCodec.normalizeAddress)
            .toSet()
            .toList()
          ..sort();
    final Map<String, String> friends = <String, String>{};
    for (final String friend in addresses) {
      final String? stored = book.friendNearbySecrets[friend];
      if (stored != null && FriendNearbyKey.parse(stored) != null) {
        friends[friend] = stored;
      }
      if (friends.length >= kNearbyKitMaxFriends) {
        break;
      }
    }
    final String? private = visible ? await meet.nearbyPrivateKey() : null;
    final int slot = nearbySlot(_now());
    final int firstSlot = slot - slot % _slotsPerDay;
    final Map<String, dynamic> inputs = <String, dynamic>{
      'me': self,
      'vis': visible,
      'al': book.alarmNearby && visible,
      'lk': book.nearbyBackgroundScan,
      'rec': recording,
      'f': friends,
      'p': private == null
          ? null
          : crypto.sha256.convert(utf8.encode(private)).toString(),
      's': firstSlot,
    };
    final String signature = crypto.sha256
        .convert(utf8.encode(jsonEncode(inputs)))
        .toString();
    if (signature == _written) {
      return false;
    }
    Uint8List? adverts;
    if (private != null) {
      try {
        adverts = await compute(_advertsFor, (
          private,
          firstSlot,
          kNearbyKitDays * _slotsPerDay,
        ));
      } on FormatException {
        adverts = null;
      }
    }
    await write(
      NearbyKit(
        createdAt: _now(),
        self: self,
        visible: visible && adverts != null,
        alarms: book.alarmNearby && visible,
        look: book.nearbyBackgroundScan,
        record: recording,
        friends: friends,
        firstSlot: firstSlot,
        adverts: adverts,
      ),
    );
    _written = signature;
    _writes += 1;
    logZenMessage(
      'Nearby kit written: ${friends.length} friend(s)'
      '${adverts == null ? '' : ', ${adverts.length ~/ kNearbyAdvertBytes} tokens'}.',
    );
    return true;
  }
}

/// "People nearby" in the Android background service while the app is
/// locked or closed, from the [NearbyKit] only:
///  - shows this phone: the kit's tokens go to the radio side at once,
///    which changes them at every slot by itself (advertising is low power;
///    nothing wakes up here for it);
///  - with "Alarm do pobliża" on, takes alarm waves (the radio side then
///    leaves them to this engine): a friend's wave whose signature checks
///    out with the friend's pair key rings the alarm notification (who it
///    is shows after unlock) and is kept for the app; anything else is at
///    most the quiet unchecked note, like in the app;
///  - with "Rozglądaj się też w tle" and "Zapisuj, kogo mijam" on, a short
///    low-power look around every [lookEvery]; friends in range (and how
///    many others) are kept for "Mijani" at most every [keepEvery].
final class LockedNearby {
  LockedNearby({
    required this.kit,
    required this.radio,
    required Future<bool> Function(SignalTransportFrame record) keep,
    required RuntimeSystemNotificationService notices,
    Future<void> Function(bool on)? claimAlarms,
    Future<void> Function(List<String> keys)? alarmKeys,
    Future<EncounterPlace?> Function()? place,
    int Function()? now,
    this.lookEvery = kNearbyLookEvery,
    this.lookFor = kNearbyLookFor,
    this.keepEvery = const Duration(minutes: 30),
  }) : _keep = keep,
       _notices = notices,
       _claimAlarms = claimAlarms,
       _alarmKeys = alarmKeys,
       _place = place,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    for (final MapEntry<String, String> e in kit.friends.entries) {
      final FriendNearbyKey? key = FriendNearbyKey.parse(e.value);
      final String friend = PeerShareCodec.normalizeAddress(e.key);
      if (key != null && friend.isNotEmpty) {
        _friends[friend] = (key, e.value);
      }
    }
  }

  final NearbyKit kit;
  final NearbyRadio radio;
  final Future<bool> Function(SignalTransportFrame record) _keep;
  final RuntimeSystemNotificationService _notices;

  /// Tells the radio side that alarm waves are answered here (or no
  /// longer), so the app's engine leaves them alone.
  final Future<void> Function(bool on)? _claimAlarms;

  /// Hands friends' pair keys to the radio side's own wave check.
  final Future<void> Function(List<String> keys)? _alarmKeys;
  final Future<EncounterPlace?> Function()? _place;
  final int Function() _now;
  final Duration lookEvery;
  final Duration lookFor;

  /// What was seen goes to the inbox at most this often (and when this
  /// stops).
  final Duration keepEvery;

  /// Friend → their key, read and as stored (the wave check takes it as
  /// stored).
  final Map<String, (FriendNearbyKey, String)> _friends =
      <String, (FriendNearbyKey, String)>{};

  /// Worked out for the slots around [_keysSlot]: hint → (friend, slot),
  /// and alarm-wave pair id → friend.
  int _keysSlot = -1;
  Map<String, List<(String, int)>> _hints = <String, List<(String, int)>>{};
  Map<String, String> _pairIds = <String, String>{};

  /// Tokens of this slot already looked at → the friend (or `null`).
  final Map<String, String?> _known = <String, String?>{};

  StreamSubscription<Map<Object?, Object?>>? _events;
  Timer? _lookTimer;
  bool _running = false;
  bool _claimed = false;
  bool _windowOpen = false;
  int _held = 0;

  /// Seen and not kept yet.
  List<Encounter> _pending = <Encounter>[];
  final Map<int, int> _crowds = <int, int>{};
  int _crowdSlot = -1;
  final Set<String> _strangers = <String>{};
  int _keptAt = 0;

  final Map<String, int> _wavesSeen = <String, int>{};
  final Map<String, List<int>> _newAlarms = <String, List<int>>{};
  final Map<String, int> _uncheckedAt = <String, int>{};
  String? _uncheckedShown;

  /// The last alarm wave being handled (tests wait for it).
  Future<void>? pendingWave;

  /// Whether alarm waves are answered here now.
  bool get receivesAlarms => _claimed;

  /// Records kept in the inbox so far (tests, logs).
  int get keptRecords => _keptRecords;
  int _keptRecords = 0;

  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    _keptAt = _now();
    _events = radio.events.listen(_onRadio);
    final Uint8List? adverts = kit.adverts;
    if (kit.visible && adverts != null) {
      if (!kit.covers(nearbySlot(_now()))) {
        logZenWarning(
          'Locked nearby: the kit holds no token for now; this phone is '
          'shown again once the app is opened.',
        );
      }
      // Bluetooth off now: the radio side shows them once it is back on.
      await radio.startAdvertisingSchedule(kit.firstSlot, adverts);
    }
    if (kit.alarms) {
      final List<String> keys = <String>[
        for (final (FriendNearbyKey, String) f in _friends.values)
          f.$1.radioKey,
      ]..sort();
      await _alarmKeys?.call(keys);
      await _claimAlarms?.call(true);
      _claimed = true;
    }
    if (kit.look && kit.record) {
      _lookTimer = Timer.periodic(
        lookEvery,
        (_) => unawaitedLogged(lookNow(), context: 'Locked nearby: look'),
      );
    }
    logZenMessage(
      'Locked nearby runs (shown: ${kit.visible}, alarm waves: ${kit.alarms}, '
      'looks: ${kit.look && kit.record}, ${_friends.length} friend key(s)).',
    );
  }

  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
    _lookTimer?.cancel();
    _lookTimer = null;
    await _events?.cancel();
    _events = null;
    if (_claimed) {
      _claimed = false;
      await _claimAlarms?.call(false);
      await _alarmKeys?.call(const <String>[]);
    }
    if (kit.visible) {
      // Only this engine's share: the app shows the phone itself.
      await radio.stopAdvertising();
    }
    if (_windowOpen) {
      await radio.stopScan();
    }
    await keepEncounters();
  }

  /// Runs [work] (this person's alarm wave, which looks around to find the
  /// phones to send to) with the radio to itself: no look around starts
  /// meanwhile, and one going on leaves the scan to [work].
  Future<T> holdingRadio<T>(Future<T> Function() work) async {
    _held += 1;
    try {
      return await work();
    } finally {
      _held -= 1;
    }
  }

  /// One short, low-power look around. Returns whether it ran.
  @visibleForTesting
  Future<bool> lookNow() async {
    if (!_running || !kit.look || !kit.record || _windowOpen || _held > 0) {
      return false;
    }
    final Map<Object?, Object?> state = await radio.state();
    if (state['permitted'] != true || state['enabled'] != true) {
      return false;
    }
    _windowOpen = true;
    try {
      if (!await radio.startScan(lowPower: true)) {
        return false;
      }
      await Future<void>.delayed(lookFor);
    } finally {
      _windowOpen = false;
      if (_held == 0) {
        await radio.stopScan();
      }
    }
    if (_running && _now() - _keptAt >= keepEvery.inMilliseconds) {
      await keepEncounters();
    }
    return true;
  }

  void _onRadio(Map<Object?, Object?> event) {
    if (!_running) {
      return;
    }
    switch (event['type']) {
      case 'seen':
        if (!kit.record || (!_windowOpen && _held == 0)) {
          return;
        }
        final Object? token = event['token'];
        final Object? hint = event['hint'];
        if (token is! List<int> || token.length < 16) {
          return;
        }
        List<int>? h = hint is List<int> && hint.length == kNearbyHintLength
            ? hint
            : null;
        if (h == null && token.length >= kNearbyAdvertBytes) {
          h = token.sublist(16, kNearbyAdvertBytes);
        }
        if (h != null) {
          _seen(token.sublist(0, 16), h);
        }
      case 'wave':
        final Object? data = event['data'];
        final Object? device = event['device'];
        if (!_claimed || event['elsewhere'] == true || data is! List<int>) {
          return;
        }
        final Object? json;
        try {
          json = jsonDecode(utf8.decode(data));
        } on FormatException {
          return;
        }
        if (json is! Map || json['v'] != kAlarmWaveVersion) {
          // Hellos and invitations wait for the app: nothing to answer
          // them with here.
          return;
        }
        final Future<void> handled = onAlarmWave(
          json,
          source: device is String ? device : '',
        );
        pendingWave = handled;
        unawaitedLogged(handled, context: 'Locked nearby: alarm wave');
    }
  }

  /// Works out the hints and pair ids around [slot] (once per slot).
  void _keysFor(int slot) {
    if (slot == _keysSlot) {
      return;
    }
    _keysSlot = slot;
    _known.clear();
    final Map<String, List<(String, int)>> hints =
        <String, List<(String, int)>>{};
    final Map<String, String> pairIds = <String, String>{};
    _friends.forEach((String friend, (FriendNearbyKey, String) f) {
      for (int s = slot - 1; s <= slot + 1; s++) {
        (hints[nearbyHex(nearbyHint(f.$1.mask, s))] ??= <(String, int)>[]).add((
          friend,
          s,
        ));
      }
      for (int s = slot - 2; s <= slot + 2; s++) {
        pairIds[nearbyPairId(f.$1.pair, s)] = friend;
      }
    });
    _hints = hints;
    _pairIds = pairIds;
  }

  /// A Zen phone showing [raw] (16 bytes) with [hint] was seen.
  void _seen(List<int> raw, List<int> hint) {
    final int at = _now();
    final int slot = nearbySlot(at);
    _keysFor(slot);
    final String token = nearbyHex(raw);
    final Uint8List? own = kit.advertAt(slot);
    if (own != null && nearbyHex(own.sublist(0, 16)) == token) {
      return;
    }
    final String? friend;
    if (_known.containsKey(token)) {
      friend = _known[token];
    } else {
      friend = _recognise(raw, nearbyHex(hint));
      if (_known.length < NearbyService.maxPeople) {
        _known[token] = friend;
      }
    }
    if (friend != null) {
      _pending = mergeEncounter(
        _pending,
        Encounter(friend: friend, start: at, end: at),
      );
      while (_pending.length > EncounterLog.maxEncounters) {
        _pending.removeLast();
      }
      return;
    }
    if (slot != _crowdSlot) {
      // Everybody's token changed: the last slot's are forgotten.
      _crowdSlot = slot;
      _strangers.clear();
    }
    if (_strangers.length < EncounterLog.maxStrangersPerSlot) {
      _strangers.add(token);
    }
    final int window = encounterWindowOf(at);
    if (_strangers.length > (_crowds[window] ?? 0)) {
      _crowds[window] = _strangers.length;
    }
  }

  /// The friend whose token [raw] is: the hint names the candidates, their
  /// hash chain proves it.
  String? _recognise(List<int> raw, String hint) {
    for (final (String friend, int slot) in _hints[hint] ?? <(String, int)>[]) {
      if (_friends[friend]?.$1.open(raw, slot) != null) {
        return friend;
      }
    }
    return null;
  }

  /// Leaves what was seen since the last time in the inbox
  /// ([kKeptEncountersType]); what could not be kept stays for the next
  /// time.
  Future<void> keepEncounters() async {
    if (_pending.isEmpty && _crowds.isEmpty) {
      return;
    }
    final List<Encounter> pending = _pending;
    final Map<int, int> crowds = Map<int, int>.of(_crowds);
    _pending = <Encounter>[];
    _crowds.clear();
    _keptAt = _now();
    EncounterPlace? place;
    if (pending.isNotEmpty) {
      try {
        place = await _place?.call();
      } on Object catch (error) {
        logZenWarning('Locked nearby: place: $error');
      }
    }
    final bool kept = await _keepRecord(<String, dynamic>{
      'type': kKeptEncountersType,
      'e': <Map<String, dynamic>>[
        for (final Encounter e in pending)
          Encounter(
            friend: e.friend,
            start: e.start,
            end: e.end,
            place: e.place ?? place,
          ).toJson(),
      ],
      'c': <List<int>>[
        for (final MapEntry<int, int> c in crowds.entries)
          <int>[c.key, c.value],
      ],
    });
    if (!kept) {
      for (final Encounter e in pending) {
        _pending = mergeEncounter(_pending, e);
      }
      crowds.forEach((int w, int n) {
        _crowds[w] = math.max(_crowds[w] ?? 0, n);
      });
    }
  }

  /// An alarm wave heard over Bluetooth, written by the phone at [source].
  @visibleForTesting
  Future<void> onAlarmWave(
    Map<dynamic, dynamic> json, {
    String source = '',
  }) async {
    final AlarmWave? wave = AlarmWave.parse(json);
    final int nowMs = _now();
    if (wave == null || !wave.isFreshAt(nowMs)) {
      return; // damaged, too old or from the future: played back?
    }
    final String who = _signedBy(wave, nowMs);
    if (!_rememberWave('$who|${wave.id}|${wave.ended}', nowMs)) {
      return;
    }
    if (who.isEmpty) {
      await _onUncheckedWave(wave, source, nowMs);
      return;
    }
    if (wave.ended || !_takeNewAlarm(who, nowMs)) {
      // Only the network copy (with the PIN's outcome) ends a friend's
      // alarm.
      return;
    }
    if (!await _keepRecord(<String, dynamic>{
      'type': MeetTypes.ownNearbyAlarm,
      'f': who,
      'id': wave.id,
      'at': nowMs,
    })) {
      logZenWarning('Locked nearby: a friend\'s alarm was not kept.');
    }
    // Loud even when it was not kept: someone close needs help now. Who it
    // is shows after unlock (no names here).
    await _show(
      RuntimeSystemNotification(
        id: '$kLockedAlarmSlot-near-${wave.id}',
        title: t('🚨 ALARM: ktoś bliski potrzebuje pomocy'),
        body: t('Jest gdzieś blisko Ciebie (Bluetooth). Otwórz i odpowiedz.'),
        createdAtMillis: nowMs,
        category: RuntimeSystemNotificationCategory.alarm,
        routeKey: buildInboxRouteKey(),
        slotKey: kLockedAlarmSlot,
        isRingingCall: true,
      ),
    );
  }

  /// The friend who signed [wave] ('' when nobody in the kit did).
  String _signedBy(AlarmWave wave, int nowMs) {
    if (!wave.signed) {
      return '';
    }
    _keysFor(nearbySlot(nowMs));
    final String? friend = _pairIds[wave.token];
    if (friend == null) {
      return '';
    }
    final (FriendNearbyKey, String)? f = _friends[friend];
    return f != null && wave.verify(f.$2) ? friend : '';
  }

  bool _rememberWave(String key, int at) {
    final int keep = 2 * kAlarmWaveFreshFor.inMilliseconds;
    _wavesSeen.removeWhere((String _, int t) => (at - t).abs() > keep);
    if (_wavesSeen.containsKey(key)) {
      return false;
    }
    while (_wavesSeen.length >= 1000) {
      _wavesSeen.remove(_wavesSeen.keys.first);
    }
    _wavesSeen[key] = at;
    return true;
  }

  bool _takeNewAlarm(String friend, int at) {
    final List<int> recent = (_newAlarms[friend] ??= <int>[])
      ..removeWhere((int t) => at - t > 3600 * 1000);
    if (recent.length >= MeetService.maxNewAlarmsPerFriendPerHour) {
      return false;
    }
    recent.add(at);
    return true;
  }

  /// A wave nobody in the kit signed: the app's quiet unchecked note, never
  /// ringing, at most one per [source] in [MeetService.unverifiedWaveEvery]
  /// and [MeetService.maxUnverifiedWaves] in all.
  Future<void> _onUncheckedWave(
    AlarmWave wave,
    String source,
    int nowMs,
  ) async {
    if (wave.ended) {
      if (_uncheckedShown == wave.id) {
        _uncheckedShown = null;
        await _notices.dismissSlot(MeetService.unverifiedWaveSlot);
      }
      return;
    }
    final String from = source.isNotEmpty
        ? source
        : wave.token.isNotEmpty
        ? wave.token
        : '?';
    _uncheckedAt.removeWhere(
      (String _, int at) =>
          (nowMs - at).abs() >= MeetService.unverifiedWaveEvery.inMilliseconds,
    );
    if (_uncheckedAt.containsKey(from) ||
        _uncheckedAt.length >= MeetService.maxUnverifiedWaves) {
      return;
    }
    _uncheckedAt[from] = nowMs;
    _uncheckedShown = wave.id;
    await _show(
      RuntimeSystemNotification(
        id: 'alarm-near-${wave.id}',
        title: t('Niesprawdzone: ktoś obok prosi o pomoc'),
        body: t(
          'Telefon w pobliżu wysłał przez Bluetooth prośbę o pomoc. '
          'Nie wiadomo, kto to, i nie da się tego sprawdzić — może to być '
          'pomyłka albo żart. Jeśli możesz bezpiecznie, rozejrzyj się. '
          'W razie zagrożenia: 112.',
        ),
        createdAtMillis: nowMs,
        category: RuntimeSystemNotificationCategory.social,
        slotKey: MeetService.unverifiedWaveSlot,
      ),
    );
  }

  Future<bool> _keepRecord(Map<String, dynamic> payload) async {
    try {
      final bool kept = await _keep(
        SignalTransportFrame(
          from: kit.self,
          payload: payload,
          receivedAtMillis: _now(),
        ),
      );
      if (kept) {
        _keptRecords += 1;
      }
      return kept;
    } on Object catch (error, stackTrace) {
      logZenError('Locked nearby: keeping failed', error, stackTrace);
      return false;
    }
  }

  Future<void> _show(RuntimeSystemNotification notice) async {
    try {
      await _notices.show(notice);
    } on Object catch (error, stackTrace) {
      logZenError('A locked nearby notice failed', error, stackTrace);
    }
  }
}
