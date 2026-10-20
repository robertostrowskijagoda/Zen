import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/plan/plan_model.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Payload types of "Plan na weekend" (§17.6).
abstract final class PlanTypes {
  /// The current copy of a plan: organizer → friends in reach, and (for
  /// friends of friends) one step further through each friend.
  static const String plan = 'weekend_plan';

  /// "Dołączam" / "Może" (no `s`: taken back). A friend of a friend sends
  /// it to the friend the plan came through, who passes it on with `by`.
  static const String answer = 'weekend_plan_ans';

  static const Set<String> all = <String>{plan, answer};
}

/// "Plan na weekend" (§17.6), the lightest of the meeting forms: a loose
/// plan goes to close friends, friends, or friends of friends; they answer
/// "Dołączam" or "Może" and everyone sees who is in (and through whom).
/// When [WeekendPlan.threshold] people join, the organizer's phone turns it
/// into an event (§17.1) for everyone who answered; without that it fades
/// after its time.
///
/// Every message goes between friends only: a friend of a friend answers
/// through the friend who passed the plan on, and that friend vouches for
/// them (like a guest of "Stół na sześć").
final class PlanService extends ChangeNotifier {
  PlanService({
    required this.host,
    required this.disk,
    this.events,
    List<String> Function()? closeFriends,
    this.convert = true,
    this.onEvent,
    int Function()? now,
    Random? random,
  }) : _closeFriends = closeFriends ?? (() => const <String>[]),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final EventHost host;
  final LedgerDisk disk;

  /// Where plans become events; `null` or [convert] off (the background
  /// service): answers are only kept, the app converts later.
  final EventService? events;
  final bool convert;

  /// Called once a plan of this person became an event (the app opens a
  /// group chat for it).
  Future<void> Function(WeekendPlan plan, MeetEvent event)? onEvent;

  final List<String> Function() _closeFriends;
  final int Function() _now;
  final Random _random;

  static const String _key = 'meet/plans';
  static const int _day = 24 * 3600 * 1000;

  /// Plans are kept this long after their time.
  static const int _keepAfter = 2 * _day;

  /// How far ahead a plan may be.
  static const int maxAhead = 60 * _day;

  /// Flood guards on the receiving side: new plans from one friend a day
  /// (their own and those they pass on), and plans of others kept in all.
  static const int maxNewPlansPerFriendPerDay = 20;
  static const int maxForeignPlans = 200;

  /// Answers one friend may pass on for their friends, per plan.
  static const int maxRelayedPerFriend = 30;

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,40}$');
  static final RegExp _addressPattern = RegExp(r'^[0-9A-Za-z:._-]{1,64}$');

  final Map<String, WeekendPlan> _plans = <String, WeekendPlan>{};

  /// Someone else's plan that came through a friend (id → that friend).
  final Map<String, String> _via = <String, String>{};

  /// This person's answers to plans of others.
  final Map<String, PlanAnswerKind> _mine = <String, PlanAnswerKind>{};

  /// What this person takes on in "Wspólna sprawa" plans of others
  /// (plan id → need key → how many).
  final Map<String, Map<String, int>> _claims = <String, Map<String, int>>{};

  /// Plans this phone passed on to its friends.
  final Set<String> _forwarded = <String>{};

  final Map<String, List<int>> _newFrom = <String, List<int>>{};
  final Map<String, int> _relays = <String, int>{};
  final Set<String> _converting = <String>{};
  Future<void> _queue = Future<void>.value();

  int get now => _now();

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  /// Plans still on screen, soonest first.
  List<WeekendPlan> get plans {
    final int t = _now();
    return _plans.values.where((WeekendPlan p) => p.showsAt(t)).toList()..sort(
      (WeekendPlan a, WeekendPlan b) => a.startsAt.compareTo(b.startsAt),
    );
  }

  WeekendPlan? plan(String id) => _plans[id];

  /// This person's answer to someone else's plan.
  PlanAnswerKind? myAnswer(String id) => _mine[id];

  /// What this person takes on in someone else's "Wspólna sprawa" [id].
  Map<String, int> myClaims(String id) =>
      Map<String, int>.unmodifiable(_claims[id] ?? const <String, int>{});

  /// The friend someone else's plan came through (`null`: from the
  /// organizer, a friend).
  String? viaOf(String id) => _via[id];

  // ---- storage ----

  /// The stored state could not be read (e.g. the app was still locked):
  /// nothing is written until a read succeeds.
  bool _diskUnreadable = false;

  Future<void> load() async {
    try {
      _diskUnreadable = true;
      final Uint8List? raw = await disk.read(_key);
      _diskUnreadable = false;
      if (raw == null) {
        return;
      }
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map) {
        return;
      }
      _plans.clear();
      for (final Object? p in (json['plans'] as List?) ?? const <Object?>[]) {
        final WeekendPlan? plan = WeekendPlan.fromJson(p);
        if (plan != null) {
          _plans[plan.id] = plan;
        }
      }
      _via.clear();
      (json['via'] as Map?)?.forEach((Object? k, Object? v) {
        if (k is String && v is String) {
          _via[k] = v;
        }
      });
      _mine.clear();
      (json['mine'] as Map?)?.forEach((Object? k, Object? v) {
        final PlanAnswerKind? kind = PlanAnswerKind.byName(v);
        if (k is String && kind != null) {
          _mine[k] = kind;
        }
      });
      _claims.clear();
      (json['claims'] as Map?)?.forEach((Object? k, Object? v) {
        if (k is String && v is Map) {
          final Map<String, int> c = <String, int>{
            for (final MapEntry<dynamic, dynamic> e in v.entries)
              if (e.key is String && e.value is int && (e.value as int) > 0)
                e.key as String: e.value as int,
          };
          if (c.isNotEmpty) {
            _claims[k] = c;
          }
        }
      });
      _forwarded
        ..clear()
        ..addAll(
          ((json['fwd'] as List?) ?? const <Object?>[]).whereType<String>(),
        );
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt planów', error, stack);
    }
  }

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    final int cutoff = _now() - _keepAfter;
    _plans.removeWhere((String _, WeekendPlan p) => p.startsAt < cutoff);
    _via.removeWhere((String id, String _) => !_plans.containsKey(id));
    _mine.removeWhere((String id, PlanAnswerKind _) => !_plans.containsKey(id));
    _forwarded.removeWhere((String id) => !_plans.containsKey(id));
    _claims.removeWhere(
      (String id, Map<String, int> _) => !_plans.containsKey(id),
    );
    await disk.write(
      _key,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'plans': <Map<String, dynamic>>[
              for (final WeekendPlan p in _plans.values) p.toJson(),
            ],
            'via': _via,
            'mine': <String, String>{
              for (final MapEntry<String, PlanAnswerKind> e in _mine.entries)
                e.key: e.value.name,
            },
            'fwd': _forwarded.toList(),
            if (_claims.isNotEmpty) 'claims': _claims,
          }),
        ),
      ),
    );
    notifyListeners();
  }

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      try {
        await work();
      } on Object catch (error, stack) {
        logZenError('Plan na weekend', error, stack);
      }
    });
  }

  /// Waits for queued work (tests).
  Future<void> get idle => _queue;

  String _newId() => List<String>.generate(
    16,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  // ---- organizing ----

  /// Friends who get this person's plan [p].
  List<String> _recipients(WeekendPlan p) =>
      p.reach == PlanReach.close ? _closeFriends() : host.friends();

  /// A new version of this person's plan [p]: later than the last one even
  /// within the same millisecond, so friends never take it for the old one.
  int _stamp(WeekendPlan p) => max(_now(), p.updatedAt + 1);

  bool _inReach(WeekendPlan p, String friend) => p.reach == PlanReach.close
      ? _closeFriends().any((String f) => _n(f) == friend)
      : host.isFriend(friend);

  /// Puts out a plan and sends it to everyone in [reach].
  Future<WeekendPlan> create({
    required String title,
    required int startsAt,
    String place = '',
    PlanReach reach = PlanReach.friends,
    int threshold = kPlanDefaultThreshold,
    List<PlanNeed> needs = const <PlanNeed>[],
  }) async {
    final String t = title.trim();
    final String pl = place.trim();
    final WeekendPlan p = WeekendPlan(
      id: _newId(),
      organizer: 'self',
      organizerName: host.ownName(),
      title: t.length > kPlanMaxTitle ? t.substring(0, kPlanMaxTitle) : t,
      place: pl.length > kPlanMaxPlace ? pl.substring(0, kPlanMaxPlace) : pl,
      startsAt: startsAt,
      reach: reach,
      threshold: threshold.clamp(kPlanMinThreshold, kPlanMaxThreshold),
      updatedAt: _now(),
      // "Wspólna sprawa": the list, re-keyed so claims always match it.
      needs: <PlanNeed>[
        for (final (int i, PlanNeed n)
            in needs
                .where((PlanNeed n) => n.label.trim().isNotEmpty)
                .take(kPlanMaxNeeds)
                .indexed)
          PlanNeed(
            key: 'n$i',
            label: n.label.trim().length > kPlanMaxNeedLabel
                ? n.label.trim().substring(0, kPlanMaxNeedLabel)
                : n.label.trim(),
            wanted: n.wanted.clamp(1, kPlanMaxNeedQty),
          ),
      ],
    );
    _plans[p.id] = p;
    await _save();
    await _broadcast(p);
    return p;
  }

  /// Takes this person's plan [id] back.
  Future<void> cancel(String id) async {
    final WeekendPlan? p = _plans[id];
    if (p == null || !p.isMine || p.cancelled) {
      return;
    }
    final WeekendPlan updated = p.copyWith(
      cancelled: true,
      updatedAt: _stamp(p),
    );
    _plans[id] = updated;
    await _save();
    await _broadcast(updated);
  }

  /// Turns this person's plan [id] into an event now, before the threshold
  /// (at least one answer is needed).
  Future<MeetEvent?> convertNow(String id) async {
    final WeekendPlan? p = _plans[id];
    return p == null ? null : _maybeConvert(p, force: true);
  }

  /// Converts this person's plans that reached their threshold meanwhile
  /// (answers taken in by the background service). Call after [load].
  Future<void> checkThresholds() async {
    for (final WeekendPlan p in _plans.values.toList()) {
      await _maybeConvert(p);
    }
  }

  /// Sends the current copy of this person's plan [p] to everyone in reach
  /// (and to those who answered, should the reach have changed under them).
  Future<void> _broadcast(WeekendPlan p) async {
    final Map<String, dynamic> json = p.toJson()
      ..['org'] = _n(host.ownAddress());
    final Set<String> to = <String>{
      for (final String f in _recipients(p)) _n(f),
      for (final PlanAnswer a in p.answers.values)
        if (a.via == null && host.isFriend(a.address)) a.address,
    };
    for (final String f in to) {
      await _send(f, <String, dynamic>{
        'type': PlanTypes.plan,
        'p': json,
        if (p.reach == PlanReach.friendsOfFriends) 'hops': 1,
      });
    }
  }

  Future<MeetEvent?> _maybeConvert(WeekendPlan p, {bool force = false}) async {
    final EventService? ev = events;
    if (!convert ||
        ev == null ||
        !p.isMine ||
        p.isEvent ||
        p.cancelled ||
        p.startsAt <= _now() ||
        (force ? p.answers.isEmpty : p.joinCount < p.threshold) ||
        !_converting.add(p.id)) {
      return null;
    }
    try {
      // The events read from disk first (right after start they may not
      // be yet), so the new one is kept with them.
      await ev.load();
      final MeetEvent e = await ev.create(
        title: p.title,
        kind: EventKind.meeting,
        startsAt: p.startsAt,
        place: p.place,
        description: p.maybe.isEmpty
            ? t('Z planu na weekend. Chętnych: {count}.', {
                'count': p.joinCount,
              })
            : t('Z planu na weekend. Chętnych: {count}, może: {maybe}.', {
                'count': p.joinCount,
                'maybe': p.maybe.length,
              }),
        invite: <String>[
          for (final PlanAnswer a in p.answers.values) a.address,
        ],
        // Friends of friends get the invitation through the friend who
        // connects them, as at "Stół na sześć".
        vouchers: <String, String>{
          for (final PlanAnswer a in p.answers.values)
            if (a.via != null) a.address: a.via!,
        },
      );
      final WeekendPlan current = _plans[p.id] ?? p;
      final WeekendPlan done = current.copyWith(
        eventId: e.id,
        updatedAt: _stamp(current),
      );
      _plans[p.id] = done;
      await _save();
      await _broadcast(done);
      await host.notify(
        RuntimeSystemNotification(
          id: 'plan-event-${p.id}',
          title: t('Jest ekipa: {title}', {'title': p.title}),
          body: t('Plan zamienił się w wydarzenie. Zaproszenia poszły.'),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'plan:${p.id}',
        ),
      );
      final Future<void> Function(WeekendPlan, MeetEvent)? hook = onEvent;
      if (hook != null) {
        try {
          await hook(done, e);
        } on Object catch (error, stack) {
          logZenError('Plan na weekend: czat', error, stack);
        }
      }
      return e;
    } finally {
      _converting.remove(p.id);
    }
  }

  // ---- answering ----

  /// "Dołączam" / "Może" to someone else's plan [id] (`null`: taken back).
  /// It goes to the organizer, or to the friend the plan came through.
  /// In a "Wspólna sprawa" a "Dołączam" may carry [claims] (need key → how
  /// many); left out, the earlier ones stay.
  Future<void> answer(
    String id,
    PlanAnswerKind? kind, {
    Map<String, int>? claims,
  }) async {
    final WeekendPlan? p = _plans[id];
    if (p == null || p.isMine || p.cancelled || p.isEvent) {
      return;
    }
    Map<String, int> sent = const <String, int>{};
    if (kind == null) {
      _mine.remove(id);
      _claims.remove(id);
    } else {
      _mine[id] = kind;
      if (kind == PlanAnswerKind.join && p.isCause) {
        sent = <String, int>{
          for (final MapEntry<String, int> e
              in (claims ?? _claims[id] ?? const <String, int>{}).entries)
            if (e.value > 0 && p.needs.any((PlanNeed n) => n.key == e.key))
              e.key: e.value.clamp(1, kPlanMaxNeedQty),
        };
      }
      if (sent.isEmpty) {
        _claims.remove(id);
      } else {
        _claims[id] = sent;
      }
    }
    await _save();
    await _send(_via[id] ?? p.organizer, <String, dynamic>{
      'type': PlanTypes.answer,
      'id': id,
      if (kind != null) 's': kind.name,
      if (sent.isNotEmpty) 'c': sent,
    });
  }

  /// "Biorę": takes on [qty] of the need [needKey] in someone else's
  /// "Wspólna sprawa" [id] (0 gives it up). It counts as joining.
  Future<void> setClaim(String id, String needKey, int qty) async {
    final WeekendPlan? p = _plans[id];
    if (p == null ||
        !p.isCause ||
        !p.needs.any((PlanNeed n) => n.key == needKey)) {
      return;
    }
    final Map<String, int> next = <String, int>{...?_claims[id]};
    if (qty <= 0) {
      next.remove(needKey);
    } else {
      next[needKey] = qty;
    }
    await answer(id, PlanAnswerKind.join, claims: next);
  }

  // ---- incoming ----

  Future<bool> handle(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type is! String || !PlanTypes.all.contains(type)) {
      return false;
    }
    final Completer<void> done = Completer<void>();
    _enqueue(() async {
      try {
        final String from = _n(frame.from);
        if (!host.isFriend(from)) {
          return;
        }
        if (type == PlanTypes.plan) {
          await _onPlan(from, frame.payload);
        } else {
          await _onAnswer(from, frame.payload);
        }
      } finally {
        done.complete();
      }
    });
    await done.future;
    return true;
  }

  /// Whether a new plan from the friend [from] may be taken in (counts it).
  bool _takeNew(String from) {
    final int t = _now();
    final List<int> recent = (_newFrom[from] ??= <int>[])
      ..removeWhere((int at) => t - at > _day);
    final int foreign = _plans.values
        .where((WeekendPlan p) => !p.isMine)
        .length;
    if (recent.length >= maxNewPlansPerFriendPerDay ||
        foreign >= maxForeignPlans) {
      return false;
    }
    recent.add(t);
    return true;
  }

  Future<void> _onPlan(String from, Map<String, dynamic> payload) async {
    final WeekendPlan? got = WeekendPlan.fromJson(payload['p']);
    if (got == null || got.organizer == 'self') {
      return;
    }
    final String org = _n(got.organizer);
    final String me = _n(host.ownAddress());
    final WeekendPlan? had = _plans[got.id];
    if (org == me || (had != null && had.isMine)) {
      return; // our own plan coming back
    }
    final int nowMs = _now();
    if (got.startsAt > nowMs + maxAhead || got.startsAt < nowMs - _keepAfter) {
      return;
    }
    final bool direct = from == org;
    final Object? hops = payload['hops'];
    if (!direct) {
      // A friend's friend's plan passed on by a friend: only for that
      // reach, one step, and not when the organizer is a friend here too
      // (then it comes from them). Later copies only through the same friend.
      if (got.reach != PlanReach.friendsOfFriends ||
          hops != 0 ||
          host.isFriend(org) ||
          (had != null && _via[got.id] != from)) {
        return;
      }
    }
    if (had != null &&
        (_n(had.organizer) != org || had.updatedAt >= got.updatedAt)) {
      return;
    }
    if (had == null && (!_idPattern.hasMatch(got.id) || !_takeNew(from))) {
      return;
    }
    final WeekendPlan stored = got.copyWith(organizer: org);
    _plans[got.id] = stored;
    if (direct) {
      _via.remove(got.id);
    } else {
      _via[got.id] = from;
    }
    await _save();
    if (had == null && !got.cancelled && !got.isEvent) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'plan-${got.id}',
          title: t('Kto chętny? {title}', {'title': got.title}),
          body: direct
              ? '${planWhen(got.startsAt, nowMs)} · ${got.organizerName}'
              : t('{when} · {name}, przez {via}', {
                  'when': planWhen(got.startsAt, nowMs),
                  'name': got.organizerName,
                  'via': host.nameOf(from),
                }),
          createdAtMillis: nowMs,
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'plan:${got.id}',
        ),
      );
    }
    // A friend's own plan for friends of friends goes one step further
    // (every newer copy, so they see who is in).
    if (direct &&
        got.reach == PlanReach.friendsOfFriends &&
        hops is int &&
        hops > 0) {
      _forwarded.add(got.id);
      await _save();
      for (final String f in host.friends()) {
        if (_n(f) != org) {
          await _send(f, <String, dynamic>{
            'type': PlanTypes.plan,
            'p': stored.toJson(),
            'hops': 0,
          });
        }
      }
    }
  }

  Future<void> _onAnswer(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final WeekendPlan? p = id is String ? _plans[id] : null;
    if (p == null || p.cancelled) {
      return;
    }
    final Object? by = payload['by'];
    final PlanAnswerKind? kind = PlanAnswerKind.byName(payload['s']);
    if (!p.isMine) {
      // As the friend who passed the plan on: a friend of ours answers
      // through us; we vouch for them to the organizer.
      final String org = _n(p.organizer);
      final int relayed = _relays[p.id] ?? 0;
      if (by != null ||
          p.isEvent ||
          _via.containsKey(p.id) ||
          !_forwarded.contains(p.id) ||
          from == org ||
          relayed >= maxRelayedPerFriend) {
        return;
      }
      _relays[p.id] = relayed + 1;
      await _send(org, <String, dynamic>{
        'type': PlanTypes.answer,
        'id': p.id,
        if (kind != null) 's': kind.name,
        if (payload['c'] is Map) 'c': payload['c'],
        'by': from,
        'n': host.nameOf(from),
      });
      return;
    }
    if (p.isEvent) {
      return; // answers are over: it is an event now
    }
    final String who;
    final String name;
    String? via;
    if (by == null) {
      if (!_inReach(p, from)) {
        return;
      }
      who = from;
      name = host.nameOf(from);
    } else {
      if (by is! String ||
          p.reach != PlanReach.friendsOfFriends ||
          !_addressPattern.hasMatch(by)) {
        return;
      }
      final String b = _n(by);
      final PlanAnswer? had = p.answers[b];
      if (b == _n(host.ownAddress()) ||
          b == from ||
          host.isFriend(b) ||
          (had != null && had.via != from) ||
          (had == null &&
              p.answers.values.where((PlanAnswer a) => a.via == from).length >=
                  maxRelayedPerFriend)) {
        return;
      }
      final Object? n = payload['n'];
      who = b;
      name = n is String && n.trim().isNotEmpty
          ? (n.trim().length > 60 ? n.trim().substring(0, 60) : n.trim())
          : t('Ktoś');
      via = from;
    }
    final Map<String, PlanAnswer> answers = Map<String, PlanAnswer>.of(
      p.answers,
    );
    if (kind == null) {
      if (answers.remove(who) == null) {
        return;
      }
    } else {
      final Map<String, int> claims = kind == PlanAnswerKind.join
          ? _acceptClaims(p, who, payload['c'])
          : const <String, int>{};
      if ((answers[who]?.kind == kind &&
              mapEquals(answers[who]?.claims, claims)) ||
          (!answers.containsKey(who) &&
              answers.length >= WeekendPlan.maxAnswers)) {
        return;
      }
      answers[who] = PlanAnswer(
        address: who,
        name: name,
        kind: kind,
        at: answers[who]?.kind == kind ? answers[who]!.at : _now(),
        via: via,
        viaName: via == null ? '' : host.nameOf(via),
        claims: claims,
      );
    }
    final WeekendPlan updated = p.copyWith(
      answers: answers,
      updatedAt: _stamp(p),
    );
    _plans[p.id] = updated;
    await _save();
    if (kind == PlanAnswerKind.join) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'plan-join-${p.id}-$who',
          title: t('{name} dołącza: {title}', {'name': name, 'title': p.title}),
          body: t('Chętnych: {count} z {threshold}.', {
            'count': updated.joinCount,
            'threshold': p.threshold,
          }),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'plan:${p.id}',
        ),
      );
    }
    await _broadcast(updated);
    await _maybeConvert(updated);
  }

  /// What [who] may take on in the "Wspólna sprawa" [p]: only things on the
  /// list, at most what is still wanted after everybody else's share.
  Map<String, int> _acceptClaims(WeekendPlan p, String who, Object? raw) {
    if (!p.isCause || raw is! Map) {
      return const <String, int>{};
    }
    final Map<String, int> out = <String, int>{};
    for (final PlanNeed n in p.needs) {
      final Object? v = raw[n.key];
      if (v is! int || v <= 0) {
        continue;
      }
      final int others = p.answers.values
          .where((PlanAnswer a) => a.address != who)
          .fold(0, (int s, PlanAnswer a) => s + (a.claims[n.key] ?? 0));
      final int take = min(v, n.wanted - others);
      if (take > 0) {
        out[n.key] = take;
      }
    }
    return out;
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Plan na weekend: do $to: $error');
    }
  }
}
