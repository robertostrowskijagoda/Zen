import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/alarm_kit.dart';
import 'package:zen/src/features/meet/alarm_shortcut.dart';
import 'package:zen/src/features/meet/location.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// After the alarm went out, when it goes again to friends whose phone has
/// not confirmed it (and to mailboxes that did not take their copy).
const List<Duration> kLockedAlarmResends = <Duration>[
  Duration(seconds: 15),
  Duration(seconds: 45),
  Duration(minutes: 2),
  Duration(minutes: 5),
  Duration(minutes: 10),
  Duration(minutes: 20),
  Duration(minutes: 40),
  Duration(minutes: 60),
];

/// A friend who has not confirmed the alarm and shows up (a ping) gets it
/// again at most this often.
const Duration kLockedAlarmPingResendEvery = Duration(seconds: 30);

/// Positions sent at most (one a minute: an hour, like the app).
const int kLockedAlarmLocationTicks = 60;

/// This person's alarm raised by the locked Android service from the
/// [AlarmKit] — the master key, the account key and the device key
/// are never here, only the alarm key.
///
/// It goes out like the app's: the Bluetooth wave first (when chosen),
/// then the alarm signed with the alarm key to every device of every
/// friend in the kit, the copies sealed in advance to the friends'
/// mailboxes; then the position every minute, sound when chosen, and
/// resends to whoever has not confirmed it. Confirmations, answers and
/// pings from friends are watched ([observe]) — they are kept in the
/// sealed inbox anyway. Everything about the alarm is left in the inbox
/// too ([MeetTypes.ownAlarm], [MeetTypes.ownAlarmAudio]): the app takes it
/// over after unlock. Only the app ends it (the PIN is there).
final class LockedAlarm {
  LockedAlarm({
    required this.kit,
    required SignalTransport transport,
    required Future<bool> Function(SignalTransportFrame record) keep,
    Future<GeoFix?> Function()? locate,
    Future<(Uint8List, int)?> Function(bool Function() cancelled)? record,
    Future<int> Function(String id, int at, bool ended)? wave,
    int Function()? now,
    this.resends = kLockedAlarmResends,
    this.locationEvery = const Duration(minutes: 1),
  }) : _transport = transport,
       _keep = keep,
       _locate = locate,
       _record = record,
       _wave = wave,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AlarmKit kit;
  final SignalTransport _transport;
  final Future<bool> Function(SignalTransportFrame record) _keep;
  final Future<GeoFix?> Function()? _locate;
  final Future<(Uint8List, int)?> Function(bool Function() cancelled)? _record;
  final Future<int> Function(String id, int at, bool ended)? _wave;
  final int Function() _now;
  final List<Duration> resends;

  /// How often the position goes out; [Duration.zero]: only once, at once.
  final Duration locationEvery;

  AlarmRecord? _alarm;

  /// The alarm as it is here now (`null` before one was raised).
  AlarmRecord? get alarm => _alarm;

  LedgerKeyPair? _key;
  bool _stopped = false;
  bool _following = false;
  Timer? _locationTimer;
  int _locationTicks = 0;
  final List<Timer> _resendTimers = <Timer>[];

  /// `mailbox|id` of mailbox copies a mailbox confirmed.
  final Set<String> _depositsTaken = <String>{};
  final Map<String, int> _pingResentAt = <String, int>{};

  /// The Bluetooth wave on its way (tests wait for it).
  Future<int>? pendingWave;

  /// The sound being recorded (tests wait for it).
  Future<void>? pendingAudio;

  /// Carries on with the kit's running alarm, if there is one.
  Future<void> start() async {
    final AlarmRecord? running = kit.running;
    if (running == null || !running.isActive || _alarm != null) {
      return;
    }
    _alarm = running;
    logZenMessage('Locked alarm carries on with a running alarm.');
    _follow();
  }

  /// Stops everything (the app takes the node back, or the service goes).
  Future<void> stop() async {
    _stopped = true;
    if (_following) {
      unawaited(ZenWake.release(tag: 'alarm'));
    }
    _locationTimer?.cancel();
    _locationTimer = null;
    for (final Timer t in _resendTimers) {
      t.cancel();
    }
    _resendTimers.clear();
  }

  /// The power-button shortcut while the app is locked or closed: the very
  /// alarm of the app's shortcut, from the kit.
  Future<ShortcutAlarmResult> raise() async {
    if (!kit.shortcut) {
      return ShortcutAlarmResult.off;
    }
    if (_alarm?.isActive ?? false) {
      return ShortcutAlarmResult.alreadyRunning;
    }
    final int t = _now();
    final AlarmRecord alarm = AlarmRecord(
      id: kit.alarmId,
      from: 'self',
      at: t,
      note: kit.note,
      sentTo: <String>[
        for (final AlarmKitRecipient r in kit.recipients) r.address,
      ],
    );
    _alarm = alarm;
    // Out first, kept after (like the app, B10).
    if (kit.nearby) {
      final Future<int> Function(String, int, bool)? wave = _wave;
      if (wave != null) {
        final Future<int> waving = wave(alarm.id, t, false).catchError((
          Object error,
        ) {
          logZenWarning('Locked alarm: Bluetooth wave failed: $error');
          return 0;
        });
        pendingWave = waving;
      }
    }
    await _broadcast();
    await _depositCopies();
    await _keepAlarm();
    logZenMessage(
      'Locked alarm raised for ${kit.recipients.length} friend(s).',
    );
    _follow();
    return ShortcutAlarmResult.raised;
  }

  Future<LedgerKeyPair> _alarmKey() async {
    final LedgerKeyPair? had = _key;
    if (had != null) {
      return had;
    }
    final Uint8List? seed = unb64(kit.alarmKeySeed, length: 32);
    if (seed == null) {
      throw const FormatException('alarm kit: damaged alarm key');
    }
    return _key = await LedgerKeyPair.fromSeed(seed);
  }

  /// The position, sound and resends that follow the alarm.
  void _follow() {
    if (_following || _stopped) {
      return;
    }
    _following = true;
    // An alarm is the one time the phone stays awake on its own: the
    // positions and resends below are timers, which stand still while it
    // sleeps. Held for as long as they run (an hour), released when the
    // app takes the alarm over.
    Duration follow = locationEvery * kLockedAlarmLocationTicks;
    for (final Duration after in resends) {
      if (after > follow) {
        follow = after;
      }
    }
    unawaited(ZenWake.hold(follow + const Duration(minutes: 1), tag: 'alarm'));
    unawaitedLogged(locateNow(), context: 'Locked alarm: position');
    if (locationEvery > Duration.zero) {
      _locationTimer = Timer.periodic(locationEvery, (Timer timer) {
        _locationTicks += 1;
        if (_stopped ||
            !(_alarm?.isActive ?? false) ||
            _locationTicks >= kLockedAlarmLocationTicks) {
          timer.cancel();
          return;
        }
        unawaitedLogged(locateNow(), context: 'Locked alarm: position');
      });
    }
    for (final Duration after in resends) {
      _resendTimers.add(
        Timer(after, () {
          unawaitedLogged(resendNow(), context: 'Locked alarm: resend');
        }),
      );
    }
    if (kit.recordAudio && _record != null) {
      pendingAudio = _recordLoop().catchError((Object error) {
        logZenWarning('Locked alarm: sound failed: $error');
      });
    }
  }

  /// Sends a fresh position (when there is one) to every friend.
  @visibleForTesting
  Future<void> locateNow() async {
    final Future<GeoFix?> Function()? locate = _locate;
    if (locate == null || _stopped || !(_alarm?.isActive ?? false)) {
      return;
    }
    final GeoFix? fix = await locate();
    final AlarmRecord? a = _alarm;
    if (fix == null || a == null || !a.isActive || _stopped) {
      return;
    }
    _alarm = a.copyWith(
      lat: fix.lat,
      lon: fix.lon,
      accuracy: fix.accuracy,
      locatedAt: _now(),
    );
    await _broadcast();
    await _keepAlarm();
  }

  /// Sends the alarm again to friends whose phone has not confirmed it,
  /// and the mailbox copies no mailbox took yet.
  @visibleForTesting
  Future<void> resendNow() async {
    final AlarmRecord? a = _alarm;
    if (a == null || !a.isActive || _stopped) {
      return;
    }
    final List<AlarmKitRecipient> unconfirmed = <AlarmKitRecipient>[
      for (final AlarmKitRecipient r in kit.recipients)
        if (a.reachOf(r.address) == AlarmReach.sent) r,
    ];
    if (unconfirmed.isNotEmpty) {
      await _broadcast(only: unconfirmed);
    }
    await _depositCopies();
  }

  /// Sends the alarm as it is now to [only] (default: every friend in the
  /// kit), at each of their devices; whoever has not confirmed it is asked
  /// to (`cf`).
  Future<void> _broadcast({List<AlarmKitRecipient>? only}) async {
    final AlarmRecord? a = _alarm;
    if (a == null) {
      return;
    }
    final Map<String, dynamic> json = a.toJson()
      ..remove('from')
      ..remove('clips')
      ..remove('near')
      ..remove('to')
      ..remove('dlv')
      ..['type'] = MeetTypes.alarm;
    Map<String, dynamic> signed = json;
    try {
      signed = await signAlarmFrame(await _alarmKey(), json);
    } on Object catch (error, stackTrace) {
      // Unsigned it still goes: friends take it as before.
      logZenError('Locked alarm: signing failed', error, stackTrace);
    }
    for (final AlarmKitRecipient r in only ?? kit.recipients) {
      final Map<String, dynamic> payload =
          a.reachOf(r.address) == AlarmReach.sent
          ? <String, dynamic>{...signed, 'cf': true}
          : signed;
      for (final String device in r.targets) {
        await _send(device, payload);
      }
    }
  }

  /// The copies sealed in advance (the kit) to the friends' mailboxes:
  /// whoever is offline gets the alarm from a mailbox once back. Only for
  /// the alarm the kit was made for (not one carried on with).
  Future<void> _depositCopies() async {
    if (kit.running != null) {
      return;
    }
    for (final AlarmKitRecipient r in kit.recipients) {
      if (_alarm?.reachOf(r.address) != AlarmReach.sent) {
        continue;
      }
      for (final AlarmKitDeposit d in r.deposits) {
        if (!_depositsTaken.contains('${d.mailbox}|${d.id}')) {
          await _send(d.mailbox, d.frame);
        }
      }
    }
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await _transport.send(remoteAddress: to, payload: payload);
    } on Object catch (error) {
      logZenWarning('Locked alarm: sending failed: $error');
    }
  }

  /// The friend in the kit [address] (a device of theirs) belongs to.
  AlarmKitRecipient? _recipientOf(String address) {
    for (final AlarmKitRecipient r in kit.recipients) {
      if (r.address == address || r.devices.contains(address)) {
        return r;
      }
    }
    return null;
  }

  /// A frame from a contact while the alarm goes on: a confirmation, an
  /// answer, a mailbox taking its copy, a friend showing up.
  void observe(SignalTransportFrame frame) {
    final AlarmRecord? a = _alarm;
    if (a == null || !a.isActive || _stopped) {
      return;
    }
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    final Map<String, dynamic> p = frame.payload;
    final Object? type = p['type'];
    if (type == 'rly_deposit_ack') {
      final Object? id = p['id'];
      if (id is String) {
        _depositsTaken.add('$from|$id');
      }
      return;
    }
    final AlarmKitRecipient? r = _recipientOf(from);
    if (r == null) {
      return;
    }
    if (type == 'ping') {
      final int t = _now();
      final int? last = _pingResentAt[r.address];
      if (a.reachOf(r.address) == AlarmReach.sent &&
          (last == null ||
              t - last >= kLockedAlarmPingResendEvery.inMilliseconds)) {
        _pingResentAt[r.address] = t;
        unawaitedLogged(
          _broadcast(only: <AlarmKitRecipient>[r]),
          context: 'Locked alarm: resend',
        );
      }
      return;
    }
    if (p['id'] != a.id) {
      return;
    }
    if (type == MeetTypes.alarmAck) {
      final Object? k = p['k'];
      if (k != 'got' && k != 'seen') {
        return;
      }
      final int t = _now();
      final AlarmDelivery had =
          a.deliveries[r.address] ?? const AlarmDelivery();
      _alarm = a.copyWith(
        deliveries: <String, AlarmDelivery>{
          ...a.deliveries,
          r.address: AlarmDelivery(
            got: had.got ?? t,
            seen: k == 'seen' ? (had.seen ?? t) : had.seen,
          ),
        },
      );
      return;
    }
    if (type == MeetTypes.alarmResponse) {
      final AlarmResponse? answer = AlarmResponse.byName(p['r']);
      if (answer == null ||
          (!a.responses.containsKey(r.address) &&
              a.responses.length >= AlarmRecord.maxResponses)) {
        return;
      }
      _alarm = a.copyWith(
        responses: <String, AlarmResponse>{...a.responses, r.address: answer},
      );
      // Everyone sees who answered (like the app).
      unawaitedLogged(_broadcast(), context: 'Locked alarm: answers');
    }
  }

  Future<void> _recordLoop() async {
    final Future<(Uint8List, int)?> Function(bool Function())? record = _record;
    if (record == null) {
      return;
    }
    while (!_stopped) {
      final AlarmRecord? a = _alarm;
      if (a == null || !a.isActive || a.clips.length >= kAlarmMaxClips) {
        return;
      }
      final (Uint8List, int)? clip = await record(
        () => _stopped || !(_alarm?.isActive ?? false),
      );
      if (clip == null) {
        return;
      }
      await _addClip(clip.$1, clip.$2);
    }
  }

  /// A piece of sound: to the friends (like the app), and into the inbox
  /// for the app.
  Future<void> _addClip(Uint8List data, int ms) async {
    final AlarmRecord? a = _alarm;
    if (a == null ||
        data.isEmpty ||
        data.length > kAlarmClipMaxBytes ||
        a.clips.length >= kAlarmMaxClips) {
      return;
    }
    final AlarmClip clip = AlarmClip(n: a.clips.length, at: _now(), ms: ms);
    _alarm = a.copyWith(clips: <AlarmClip>[...a.clips, clip]);
    final Map<String, dynamic> piece = <String, dynamic>{
      'id': a.id,
      'n': clip.n,
      'at': clip.at,
      'ms': clip.ms,
      'd': base64Encode(data),
    };
    for (final AlarmKitRecipient r in kit.recipients) {
      await _send(r.address, <String, dynamic>{
        'type': MeetTypes.alarmAudio,
        ...piece,
      });
    }
    if (!await _keepRecord(<String, dynamic>{
      'type': MeetTypes.ownAlarmAudio,
      ...piece,
    })) {
      logZenWarning('Locked alarm: a piece of sound was not kept.');
    }
  }

  Future<void> _keepAlarm() async {
    final AlarmRecord? a = _alarm;
    if (a == null) {
      return;
    }
    if (!await _keepRecord(<String, dynamic>{
      'type': MeetTypes.ownAlarm,
      'a': a.toJson(),
    })) {
      logZenWarning('Locked alarm: the alarm was not kept for the app.');
    }
  }

  Future<bool> _keepRecord(Map<String, dynamic> payload) async {
    try {
      return await _keep(
        SignalTransportFrame(
          from: kit.self,
          payload: payload,
          receivedAtMillis: _now(),
        ),
      );
    } on Object catch (error, stackTrace) {
      logZenError('Locked alarm: keeping failed', error, stackTrace);
      return false;
    }
  }
}

/// The Bluetooth alarm wave from the locked service: looks around
/// for [listen], then sends every phone seen the wave — signed with the
/// pair key for a friend in [kit] recognised by their token (only they can
/// check it), unsigned for everyone else ("someone nearby needs help").
/// Returns how many phones got it.
Future<int> waveLockedAlarm(
  NearbyRadio radio,
  AlarmKit kit, {
  required String id,
  required int at,
  bool ended = false,
  Duration listen = const Duration(seconds: 6),
  int Function()? now,
}) async {
  final Map<Object?, Object?> state = await radio.state();
  if (state['permitted'] != true || state['enabled'] != true) {
    return 0;
  }
  final Map<String, (List<int>, List<int>?)> seen =
      <String, (List<int>, List<int>?)>{};
  final StreamSubscription<Map<Object?, Object?>> sub = radio.events.listen((
    Map<Object?, Object?> event,
  ) {
    if (event['type'] != 'seen') {
      return;
    }
    final Object? token = event['token'];
    final Object? device = event['device'];
    final Object? hint = event['hint'];
    if (token is List<int> && token.length >= 16 && device is String) {
      List<int>? h = hint is List<int> && hint.length == kNearbyHintLength
          ? hint
          : null;
      if (h == null && token.length >= 16 + kNearbyHintLength) {
        h = token.sublist(16, 16 + kNearbyHintLength);
      }
      seen[device] = (token.sublist(0, 16), h);
    }
  });
  try {
    if (!await radio.startScan()) {
      return 0;
    }
    await Future<void>.delayed(listen);
  } finally {
    await radio.stopScan();
    await sub.cancel();
  }
  final int slot = nearbySlot(
    (now ?? () => DateTime.now().millisecondsSinceEpoch)(),
  );
  final List<(FriendNearbyKey, List<int>)> friends =
      <(FriendNearbyKey, List<int>)>[
        for (final AlarmKitRecipient r in kit.recipients)
          if (FriendNearbyKey.parse(r.nearbyKey) case final FriendNearbyKey key)
            if (unb64(r.pairKey, length: 32) case final Uint8List pair)
              (key, pair),
      ];
  List<int>? pairFor(List<int> token, List<int>? hint) {
    for (final (FriendNearbyKey key, List<int> pair) in friends) {
      for (int s = slot - 1; s <= slot + 1; s++) {
        if (hint != null && !_same(nearbyHint(key.mask, s), hint)) {
          continue;
        }
        if (key.open(token, s) != null) {
          return pair;
        }
      }
    }
    return null;
  }

  final Map<String, dynamic> open = AlarmWave.build(
    id: id,
    at: at,
    ended: ended,
  );
  int sent = 0;
  for (final MapEntry<String, (List<int>, List<int>?)> e in seen.entries) {
    final List<int>? pair = pairFor(e.value.$1, e.value.$2);
    final Map<String, dynamic> wave = pair == null
        ? open
        : AlarmWave.buildPair(id: id, at: at, ended: ended, pairKey: pair);
    if (await radio.wave(
      e.key,
      Uint8List.fromList(utf8.encode(jsonEncode(wave))),
    )) {
      sent += 1;
    }
  }
  return sent;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
