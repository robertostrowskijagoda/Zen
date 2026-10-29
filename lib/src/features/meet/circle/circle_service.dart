import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/circle/circle_model.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/locked_reminders.dart';
import 'package:zen/src/features/meet/meet_thread.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

export 'package:zen/src/features/meet/circle/circle_model.dart';

abstract final class CircleTypes {
  /// The circle itself (`c`), or, with `k`, one member's step: "ans" (an
  /// invitation answered), "leave" ("Opuść kółko"), "chat" (the small chat
  /// of one dinner).
  static const String circle = 'circle';
  static const String swap = 'circle_swap';

  /// "Kółko otwarte": a member invites someone from outside for one dinner.
  static const String guest = 'circle_guest';

  static const Set<String> all = <String>{circle, swap, guest};
}

/// How far a phone's clock may be ahead: a copy of a circle dated later
/// than that counts as made now (a date far ahead would freeze the circle
/// against everyone else's later changes).
const Duration kCircleClockSkew = Duration(minutes: 10);

/// When "Jak było?" is asked: this long after a dinner starts...
const Duration kCircleHowAfter = Duration(hours: 3);

/// ...and until this long after it.
const Duration kCircleHowUntil = Duration(hours: 48);

/// The reminder comes within this long before a dinner.
const Duration kCircleRemindBefore = Duration(hours: 24);

final class CircleService extends ChangeNotifier {
  CircleService({
    required this.host,
    required this.disk,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final EventHost host;
  final LedgerDisk disk;
  final int Function() _now;
  final Random _random;
  static const String _key = 'meet/circles';

  final Map<String, DinnerCircle> _circles = <String, DinnerCircle>{};

  /// Circles this person declined or left, and when: an older copy that
  /// still lists them is not taken as a new invitation.
  final Map<String, int> _declined = <String, int>{};

  /// Reminders and "Jak było?" already shown (circle id | day | kind).
  final Set<String> _shown = <String>{};

  /// The small chat of each dinner (circle id | day).
  final MeetThreads _threads = MeetThreads();

  /// Swap requests waiting for this person (circle id → who asks).
  final Map<String, String> swapRequests = <String, String>{};

  int get now => _now();

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  String get _me => _n(host.ownAddress());

  /// Circles this person is a member of.
  List<DinnerCircle> get circles =>
      _circles.values.where((DinnerCircle c) => c.hasMember(_me)).toList();

  /// Invitations waiting for "Dołączam" / "Nie, dziękuję".
  List<DinnerCircle> get invitations => _circles.values
      .where((DinnerCircle c) => !c.hasMember(_me) && c.isInvited(_me))
      .toList();

  DinnerCircle? circle(String id) => _circles[id];

  /// The stored state could not be read (e.g. the app was still locked):
  /// nothing is written until a read succeeds, so empty memory never
  /// replaces the real data.
  bool _diskUnreadable = false;

  Future<void> load() async {
    try {
      _diskUnreadable = true;
      final List<int>? raw = await disk.read(_key);
      _diskUnreadable = false;
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json is Map) {
        _circles.clear();
        for (final Object? c in (json['c'] as List?) ?? const <Object?>[]) {
          final DinnerCircle? circle = DinnerCircle.fromJson(c);
          if (circle != null) {
            _circles[circle.id] = circle;
          }
        }
        _declined.clear();
        (json['dec'] as Map?)?.forEach((Object? k, Object? v) {
          if (k is String && v is int) {
            _declined[k] = v;
          }
        });
        _shown
          ..clear()
          ..addAll(
            ((json['shown'] as List?) ?? const <Object?>[]).whereType<String>(),
          );
        _threads.readJson(json['chat']);
      }
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Reading circles', error, stack);
    }
  }

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    while (_shown.length > 300) {
      _shown.remove(_shown.first);
    }
    while (_declined.length > 200) {
      _declined.remove(_declined.keys.first);
    }
    _threads.removeWhere(
      (String key) => !_circles.containsKey(key.split('|').first),
    );
    await disk.write(
      _key,
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'c': <Map<String, dynamic>>[
            for (final DinnerCircle c in _circles.values) c.toJson(),
          ],
          'dec': _declined,
          'shown': _shown.toList(),
          'chat': _threads.toJson(),
        }),
      ),
    );
    notifyListeners();
  }

  /// Everyone a copy of [c] goes to: the members and those invited.
  Iterable<String> _audience(DinnerCircle c) => <String>{
    for (final CircleMember m in c.members) m.address,
    ...c.invited.keys,
  }.where((String a) => a != _me);

  /// Stores [c] and sends it to everyone in it. [bump]: a change of the
  /// circle's settings (the newest copy wins them); per-member answers
  /// merge entry by entry and leave the date alone, so they never override
  /// someone else's newer settings.
  Future<void> _publish(DinnerCircle c, {bool bump = true}) async {
    // Always newer than the copy we have, even when another phone's clock
    // ran a little ahead.
    final DinnerCircle stamped = bump
        ? c.copyWith(
            updatedAt: max(_now(), (_circles[c.id]?.updatedAt ?? 0) + 1),
          )
        : c;
    final DinnerCircle kept = stamped.prunedBefore(
      _now() - kCircleDinnerKeep.inMilliseconds,
    );
    _circles[c.id] = kept;
    await _save();
    for (final String to in _audience(kept)) {
      await _send(to, <String, dynamic>{
        'type': CircleTypes.circle,
        'c': kept.toJson(),
      });
    }
  }

  String _newId(int length) => List<String>.generate(
    length,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  /// Founds a circle: this person is its first member, [friends] get an
  /// invitation ("Dołączam" / "Nie, dziękuję"). 4–8 people with the
  /// founder.
  Future<DinnerCircle> create({
    required String name,
    required List<String> friends,
    required int weekday,
    required int hour,
    required DateTime firstDinner,
    int everyWeeks = 1,
    bool pairs = false,
  }) async {
    final Set<String> unique = <String>{
      for (final String f in friends)
        if (_n(f) != _me) _n(f),
    };
    if (!DinnerCircle.validSize(unique.length + 1)) {
      throw ArgumentError.value(
        unique.length + 1,
        'friends',
        'a circle has $kCircleMinMembers–$kCircleMaxMembers members',
      );
    }
    final int stamp = _now();
    final DinnerCircle c = DinnerCircle(
      pairs: pairs,
      id: _newId(14),
      name: name,
      members: <CircleMember>[
        CircleMember(_me, host.ownName(), pos: stamp, at: stamp),
      ],
      invited: <String, CircleInvite>{
        for (final String f in unique)
          f: CircleInvite(name: host.nameOf(f), by: _me, at: stamp),
      },
      weekday: weekday,
      hour: hour,
      firstDinner: DateTime(
        firstDinner.year,
        firstDinner.month,
        firstDinner.day,
      ).millisecondsSinceEpoch,
      everyWeeks: everyWeeks,
    );
    await _publish(c);
    return _circles[c.id]!;
  }

  /// Invites more of this person's friends (while the circle has room).
  /// Returns how many were invited.
  Future<int> invite(String id, List<String> friends) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || !c.hasMember(_me)) {
      return 0;
    }
    final int stamp = _now();
    final Map<String, CircleInvite> invited = <String, CircleInvite>{
      ...c.invited,
    };
    int added = 0;
    for (final String f in friends.map(_n)) {
      if (f == _me ||
          c.hasMember(f) ||
          invited.containsKey(f) ||
          !host.isFriend(f) ||
          c.members.length + invited.length >= kCircleMaxMembers) {
        continue;
      }
      invited[f] = CircleInvite(name: host.nameOf(f), by: _me, at: stamp);
      added++;
    }
    if (added > 0) {
      await _publish(c.copyWith(invited: invited));
    }
    return added;
  }

  /// "Dołączam" ([yes]) or "Nie, dziękuję" to the invitation to [id]. The
  /// members hear it; joining puts this person at the end of the queue.
  Future<void> answerInvite(String id, bool yes) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || c.hasMember(_me) || !c.isInvited(_me)) {
      return;
    }
    final int stamp = max(_now(), c.invited[_me]!.at + 1);
    final List<String> tell = _audience(c).toList();
    if (yes) {
      _circles[id] = c.copyWith(
        members: <CircleMember>[
          ...c.members,
          CircleMember(_me, host.ownName(), pos: stamp, at: stamp),
        ],
        invited: <String, CircleInvite>{...c.invited}..remove(_me),
      );
    } else {
      _circles.remove(id);
      _declined[id] = stamp;
    }
    await _save();
    for (final String to in tell) {
      await _send(to, <String, dynamic>{
        'type': CircleTypes.circle,
        'k': 'ans',
        'id': id,
        'y': yes,
        't': stamp,
        'n': host.ownName(),
      });
    }
  }

  /// "Opuść kółko": the others hear it and the queue is worked out again
  /// without this person.
  Future<void> leave(String id) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || !c.hasMember(_me)) {
      return;
    }
    final int stamp = max(_now(), (c.member(_me)?.at ?? 0) + 1);
    final List<String> tell = _audience(c).toList();
    _circles.remove(id);
    _declined[id] = stamp;
    swapRequests.remove(id);
    await _save();
    for (final String to in tell) {
      await _send(to, <String, dynamic>{
        'type': CircleTypes.circle,
        'k': 'leave',
        'id': id,
        't': stamp,
      });
    }
  }

  Future<void> setMyPrefs(String id, String text) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || !c.hasMember(_me)) {
      return;
    }
    await _publish(
      c.copyWith(prefs: <String, String>{...c.prefs, _me: text.trim()}),
    );
  }

  /// What this person does not eat (for the cook's count).
  Future<void> setMyDiets(String id, Set<CircleDiet> diets) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || !c.hasMember(_me)) {
      return;
    }
    await _publish(
      c.copyWith(
        diets: <String, Set<CircleDiet>>{
          ...c.diets,
          _me: Set<CircleDiet>.of(diets),
        },
      ),
    );
  }

  /// "Będę" / "Nie dam rady" / "Może" for the dinner on [day].
  Future<void> rsvp(String id, DateTime day, CircleAttendance answer) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || !c.hasMember(_me)) {
      return;
    }
    await _publish(
      c.copyWith(
        rsvp: DinnerCircle.withMark<CircleAttendance>(
          c.rsvp,
          DinnerCircle.dayKey(day),
          _me,
          CircleMark<CircleAttendance>(answer, _now()),
        ),
      ),
      bump: false,
    );
  }

  /// "Wydałem(-am) na zakupy" for the dinner on [day], in grosze (0 takes
  /// it back). Returns whether it was saved.
  Future<bool> setSpent(String id, DateTime day, int cents) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || !c.hasMember(_me) || cents < 0 || cents > 100000000) {
      return false;
    }
    await _publish(
      c.copyWith(
        spent: DinnerCircle.withMark<int>(
          c.spent,
          DinnerCircle.dayKey(day),
          _me,
          CircleMark<int>(cents, _now()),
        ),
      ),
      bump: false,
    );
    return true;
  }

  /// "Rozliczone ✓": [transfer] of the dinner on [day] was paid back, as
  /// one of its two sides says.
  Future<void> markSettled(
    String id,
    DateTime day,
    CircleTransfer transfer,
  ) async {
    final DinnerCircle? c = _circles[id];
    final String key = DinnerCircle.dayKey(day);
    if (c == null ||
        !c.hasMember(_me) ||
        (transfer.from != _me && transfer.to != _me) ||
        !c.settleUp(key).contains(transfer)) {
      return;
    }
    await _publish(
      c.copyWith(
        settled: <String, Map<String, int>>{
          ...c.settled,
          key: <String, int>{...?c.settled[key], transfer.key: _now()},
        },
      ),
      bump: false,
    );
  }

  /// "Jak było?" after the dinner on [day].
  Future<void> rate(String id, DateTime day, CircleHow how) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || !c.hasMember(_me)) {
      return;
    }
    await _publish(
      c.copyWith(
        how: DinnerCircle.withMark<CircleHow>(
          c.how,
          DinnerCircle.dayKey(day),
          _me,
          CircleMark<CircleHow>(how, _now()),
        ),
      ),
      bump: false,
    );
  }

  /// The dinner to ask "Jak było?" about now: the last one, from
  /// [kCircleHowAfter] to [kCircleHowUntil] after it started, when this
  /// person did not say "Nie dam rady" and did not answer yet.
  DateTime? howPending(String id) {
    final DinnerCircle? c = _circles[id];
    final int nowMs = _now();
    final (DateTime, CircleMember)? last = c?.lastDinner(nowMs);
    if (c == null || last == null || !c.hasMember(_me)) {
      return null;
    }
    final int since = nowMs - last.$1.millisecondsSinceEpoch;
    final String day = DinnerCircle.dayKey(last.$1);
    if (since < kCircleHowAfter.inMilliseconds ||
        since > kCircleHowUntil.inMilliseconds ||
        c.attendanceOf(_me, day) == CircleAttendance.no ||
        c.how[day]?[_me] != null) {
      return null;
    }
    return last.$1;
  }

  /// The last dinner, while "Spotkani?" is still asked about it: from its
  /// start until [kCircleHowUntil] after, when this person did not say
  /// "Nie dam rady".
  DateTime? metPending(String id) {
    final DinnerCircle? c = _circles[id];
    final int nowMs = _now();
    final (DateTime, CircleMember)? last = c?.lastDinner(nowMs);
    if (c == null || last == null || !c.hasMember(_me)) {
      return null;
    }
    final int since = nowMs - last.$1.millisecondsSinceEpoch;
    return since > kCircleHowUntil.inMilliseconds ||
            c.attendanceOf(_me, DinnerCircle.dayKey(last.$1)) ==
                CircleAttendance.no
        ? null
        : last.$1;
  }

  /// Whom to ask "Spotkani?" about after the dinner on [day]: people there
  /// who are not this person's friends yet.
  List<(String, String)> newPeopleAt(String id, DateTime day) =>
      _circles[id]?.newPeopleOn(day, me: _me, known: host.isFriend) ??
      const <(String, String)>[];

  // ---- the small chat of a dinner ----

  static String threadKey(String id, DateTime day) =>
      '$id|${DinnerCircle.dayKey(day)}';

  List<MeetThreadMessage> thread(String id, DateTime day) =>
      _threads.thread(threadKey(id, day));

  int unread(String id, DateTime day) => _threads.unread(threadKey(id, day));

  Future<void> markRead(String id, DateTime day) async {
    final String key = threadKey(id, day);
    if (_threads.unread(key) == 0) {
      return;
    }
    _threads.markRead(key, _now());
    await _save();
  }

  /// Writes [text] in the chat of the dinner on [day] ("Spóźnię się 10
  /// min"): every member gets it.
  Future<bool> sendChat(String id, DateTime day, String text) async {
    final DinnerCircle? c = _circles[id];
    final String? clean = cleanThreadText(text);
    if (c == null || clean == null || !c.hasMember(_me)) {
      return false;
    }
    final MeetThreadMessage m = MeetThreadMessage(
      id: newThreadMessageId(_random),
      from: _me,
      text: clean,
      at: _now(),
      mine: true,
    );
    _threads
      ..add(threadKey(id, day), m)
      ..markRead(threadKey(id, day), m.at);
    await _save();
    for (final CircleMember member in c.members) {
      if (member.address != _me) {
        await _send(member.address, <String, dynamic>{
          'type': CircleTypes.circle,
          'k': 'chat',
          'id': id,
          'd': DinnerCircle.dayKey(day),
          'm': m.id,
          'x': m.text,
          't': m.at,
        });
      }
    }
    return true;
  }

  // ---- reminders ----

  /// The day before a dinner, a reminder (to the cook with the count so
  /// far); a few hours after it, "Jak było?". Each once. Called now and
  /// then while the app runs.
  Future<void> tick() async {
    final int nowMs = _now();
    bool changed = false;
    for (final DinnerCircle c in circles) {
      final (DateTime, CircleMember)? next = c
          .schedule(nowMs, count: 1)
          .firstOrNull;
      if (next != null) {
        final int start = next.$1.millisecondsSinceEpoch;
        final String day = DinnerCircle.dayKey(next.$1);
        if (start > nowMs &&
            start - nowMs <= kCircleRemindBefore.inMilliseconds &&
            _shown.add('${c.id}|$day|remind')) {
          changed = true;
          await _remind(c, next.$1, next.$2);
        }
      }
      final DateTime? how = howPending(c.id);
      if (how != null &&
          _shown.add('${c.id}|${DinnerCircle.dayKey(how)}|how')) {
        changed = true;
        await host.notify(_howFor(c, DinnerCircle.dayKey(how)));
      }
    }
    if (changed) {
      await _save();
    }
  }

  Future<void> _remind(DinnerCircle c, DateTime at, CircleMember cook) =>
      host.notify(_reminderFor(c, at, cook));

  /// The reminder the day before the dinner at [at] (the cook gets the
  /// count so far).
  RuntimeSystemNotification _reminderFor(
    DinnerCircle c,
    DateTime at,
    CircleMember cook,
  ) {
    final String when = ZenFormat.time(at);
    final String day = DinnerCircle.dayKey(at);
    if (cook.address == _me) {
      return RuntimeSystemNotification(
        id: 'circle-remind-${c.id}-$day',
        title: t('Jutro gotujesz: {circle}', {'circle': c.name}),
        body: circleCountText(c.headcountOn(at)),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'circle:${c.id}',
      );
    }
    return RuntimeSystemNotification(
      id: 'circle-remind-${c.id}-$day',
      title: t('Jutro obiad: {circle}', {'circle': c.name}),
      body: c.attendanceOf(_me, day) == null
          ? t('O {time} gotuje {name}. Będziesz? Odpowiedz w aplikacji.', {
              'time': when,
              'name': cook.name,
            })
          : t('O {time} gotuje {name}.', {'time': when, 'name': cook.name}),
      createdAtMillis: _now(),
      category: RuntimeSystemNotificationCategory.social,
      slotKey: 'circle:${c.id}',
    );
  }

  RuntimeSystemNotification _howFor(DinnerCircle c, String day) =>
      RuntimeSystemNotification(
        id: 'circle-how-${c.id}-$day',
        title: t('Jak było? {circle}', {'circle': c.name}),
        body: t(
          'Odpowiedz jednym stuknięciem. Zobacz też, kto gotuje '
          'następnym razem.',
        ),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'circle:${c.id}',
      );

  /// The reminders of the coming [ahead] worked out now, for the Android
  /// background service to show while the app is locked or closed (it
  /// cannot read the circles): the day before each dinner and "Jak było?"
  /// after it, with the same ids as [tick] uses. Only those still ahead,
  /// so the list stays the same between two calls.
  List<LockedReminder> lockedReminders({
    Duration ahead = const Duration(days: 8),
  }) {
    final int nowMs = _now();
    final List<LockedReminder> out = <LockedReminder>[];
    LockedReminder from(RuntimeSystemNotification n, int at) => LockedReminder(
      id: n.id,
      at: at,
      title: n.title,
      body: n.body,
      slot: n.slotKey ?? '',
    );
    for (final DinnerCircle c in circles) {
      for (final (DateTime at, CircleMember cook) in c.schedule(
        nowMs,
        count: 3,
      )) {
        final int start = at.millisecondsSinceEpoch;
        if (start - nowMs > ahead.inMilliseconds) {
          break;
        }
        final String day = DinnerCircle.dayKey(at);
        final int remindAt = start - kCircleRemindBefore.inMilliseconds;
        if (remindAt > nowMs && !_shown.contains('${c.id}|$day|remind')) {
          out.add(from(_reminderFor(c, at, cook), remindAt));
        }
        final int howAt = start + kCircleHowAfter.inMilliseconds;
        if (howAt > nowMs &&
            c.attendanceOf(_me, day) != CircleAttendance.no &&
            c.how[day]?[_me] == null) {
          out.add(from(_howFor(c, day), howAt));
        }
      }
    }
    out.sort((LockedReminder a, LockedReminder b) => a.at.compareTo(b.at));
    return out.take(kLockedRemindersMax).toList();
  }

  // ---- the rest of a circle ----

  /// Adds something to bring to the dinner on [day] (unclaimed).
  Future<void> addItem(String id, DateTime day, String item) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || item.trim().isEmpty) {
      return;
    }
    final String key = DinnerCircle.dayKey(day);
    await _publish(
      c.copyWith(
        items: <String, Map<String, String>>{
          ...c.items,
          key: <String, String>{...?c.items[key], item.trim(): ''},
        },
      ),
    );
  }

  /// "Ja przynoszę" (or, again, "już nie").
  Future<void> claimItem(String id, DateTime day, String item) async {
    final DinnerCircle? c = _circles[id];
    final String key = DinnerCircle.dayKey(day);
    final String? who = c?.items[key]?[item];
    if (c == null || who == null) {
      return;
    }
    await _publish(
      c.copyWith(
        items: <String, Map<String, String>>{
          ...c.items,
          key: <String, String>{...c.items[key]!, item: who == _me ? '' : _me},
        },
      ),
    );
  }

  /// Asks [other] to swap places in the hosting order.
  Future<void> askSwap(String id, String other) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || !c.hasMember(other)) {
      return;
    }
    await _send(_n(other), <String, dynamic>{
      'type': CircleTypes.swap,
      'id': id,
    });
  }

  /// Agrees to the swap [from] asked for.
  Future<void> acceptSwap(String id) async {
    final DinnerCircle? c = _circles[id];
    final String? from = swapRequests.remove(id);
    if (c == null || from == null) {
      return;
    }
    final CircleMember? a = c.member(_me);
    final CircleMember? b = c.member(from);
    if (a == null || b == null) {
      notifyListeners();
      return;
    }
    await _publish(
      c.copyWith(
        members: <CircleMember>[
          for (final CircleMember m in c.members)
            if (m.address == a.address)
              m.withPos(b.pos)
            else if (m.address == b.address)
              m.withPos(a.pos)
            else
              m,
        ],
      ),
    );
  }

  void declineSwap(String id) {
    swapRequests.remove(id);
    notifyListeners();
  }

  /// Opens (or closes) the circle: once a month every member may bring
  /// one person from outside.
  Future<void> setOpen(String id, bool open) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || c.open == open) {
      return;
    }
    await _publish(c.copyWith(open: open));
  }

  /// Brings [name] (a friend at [address], who then gets an invitation,
  /// or anyone by name) to the dinner on [day]. Once a month, in an open
  /// circle. Returns whether it worked.
  Future<bool> bringGuest(
    String id,
    DateTime day, {
    required String name,
    String? address,
    bool vouch = false,
  }) async {
    final DinnerCircle? c = _circles[id];
    final String n = name.trim();
    // The one who brings a guest vouches for them: no vouching, no guest.
    if (!vouch || c == null || n.isEmpty || !c.canBringGuest(_me, day)) {
      return false;
    }
    if (address != null && c.hasMember(address)) {
      return false; // already in the circle
    }
    final String month = DinnerCircle.monthKey(day);
    final CircleGuest guest = CircleGuest(
      name: n.length > 60 ? n.substring(0, 60) : n,
      day: DinnerCircle.dayKey(day),
      address: address == null ? null : _n(address),
      vouchedBy: _me,
    );
    await _publish(
      c.copyWith(
        guests: <String, Map<String, CircleGuest>>{
          ...c.guests,
          month: <String, CircleGuest>{...?c.guests[month], _me: guest},
        },
      ),
    );
    final String? to = guest.address;
    if (to != null) {
      final CircleMember? cook = c
          .schedule(day.millisecondsSinceEpoch, count: 1)
          .firstOrNull
          ?.$2;
      await _send(to, <String, dynamic>{
        'type': CircleTypes.guest,
        'c': c.name,
        'at': DateTime(
          day.year,
          day.month,
          day.day,
          c.hour,
        ).millisecondsSinceEpoch,
        if (cook != null) 'cook': cook.name,
      });
    }
    return true;
  }

  /// Records that this person put [cents] grosze into the kitty (negative:
  /// took money out, e.g. a reimbursement). Returns whether it was saved.
  Future<bool> addToKitty(String id, int cents, {String note = ''}) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || cents == 0 || cents.abs() > 100000000) {
      return false;
    }
    final String text = note.trim();
    final List<KittyEntry> all = <KittyEntry>[
      ...c.kitty,
      KittyEntry(
        by: _me,
        cents: cents,
        at: _now(),
        note: text.length > 60 ? text.substring(0, 60) : text,
      ),
    ];
    await _publish(
      c.copyWith(
        kitty: all.length > kCircleKittyMax
            ? all.sublist(all.length - kCircleKittyMax)
            : all,
      ),
    );
    return true;
  }

  /// Removes this person's own kitty entry at [index] (a mistake).
  Future<void> removeKittyEntry(String id, int index) async {
    final DinnerCircle? c = _circles[id];
    if (c == null ||
        index < 0 ||
        index >= c.kitty.length ||
        c.kitty[index].by != _me) {
      return;
    }
    await _publish(
      c.copyWith(kitty: <KittyEntry>[...c.kitty]..removeAt(index)),
    );
  }

  /// Takes back this person's guest for the month of [day].
  Future<void> cancelGuest(String id, DateTime day) async {
    final DinnerCircle? c = _circles[id];
    final String month = DinnerCircle.monthKey(day);
    if (c == null || c.guests[month]?[_me] == null) {
      return;
    }
    final Map<String, CircleGuest> left = <String, CircleGuest>{
      ...c.guests[month]!,
    }..remove(_me);
    final Map<String, Map<String, CircleGuest>> guests =
        <String, Map<String, CircleGuest>>{...c.guests};
    if (left.isEmpty) {
      guests.remove(month);
    } else {
      guests[month] = left;
    }
    await _publish(c.copyWith(guests: guests));
  }

  // ---- incoming ----

  Future<bool> handle(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type is! String || !CircleTypes.all.contains(type)) {
      return false;
    }
    final String from = _n(frame.from);
    if (type == CircleTypes.guest) {
      await _onGuest(from, frame.payload);
      return true;
    }
    if (type == CircleTypes.swap) {
      final Object? id = frame.payload['id'];
      final DinnerCircle? c = id is String ? _circles[id] : null;
      if (c != null && c.hasMember(from) && c.hasMember(_me)) {
        swapRequests[c.id] = from;
        notifyListeners();
        await host.notify(
          RuntimeSystemNotification(
            id: 'circle-swap-${c.id}-$from',
            title: t('{name} chce zamienić się kolejką', {
              'name': c.nameIn(from) ?? host.nameOf(from),
            }),
            body: c.name,
            createdAtMillis: _now(),
            category: RuntimeSystemNotificationCategory.social,
            slotKey: 'circle:${c.id}',
          ),
        );
      }
      return true;
    }
    switch (frame.payload['k']) {
      case null:
        await _onCopy(from, frame.payload);
      case 'ans':
        await _onAnswer(from, frame.payload);
      case 'leave':
        await _onLeave(from, frame.payload);
      case 'chat':
        await _onChat(from, frame.payload);
    }
    return true;
  }

  int get _latest => _now() + kCircleClockSkew.inMilliseconds;

  Future<void> _onGuest(String from, Map<String, dynamic> payload) async {
    // A friend brings us to their circle's dinner.
    final Object? name = payload['c'];
    final Object? at = payload['at'];
    final Object? cook = payload['cook'];
    if (!host.isFriend(from) || name is! String || at is! int) {
      return;
    }
    final DateTime d = DateTime.fromMillisecondsSinceEpoch(at);
    final Map<String, Object?> args = <String, Object?>{
      'circle': name.length > 60 ? name.substring(0, 60) : name,
      'date': ZenFormat.dayMonth(d),
      'time': ZenFormat.time(DateTime(d.year, d.month, d.day, d.hour)),
    };
    await host.notify(
      RuntimeSystemNotification(
        id: 'circle-guest-$from-$at',
        title: t('{name} zaprasza Cię na obiad', {'name': host.nameOf(from)}),
        body: cook is String && cook.isNotEmpty
            ? t('„{circle}”, {date} o {time} — gotuje {cook}.', {
                ...args,
                'cook': cook.length > 60 ? cook.substring(0, 60) : cook,
              })
            : t('„{circle}”, {date} o {time}.', args),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'circle-guest:$from',
      ),
    );
  }

  /// A member's copy of a circle: a new invitation, or merged into ours.
  Future<void> _onCopy(String from, Map<String, dynamic> payload) async {
    final DinnerCircle? parsed = DinnerCircle.fromJson(payload['c']);
    if (parsed == null) {
      return;
    }
    final DinnerCircle got = parsed.clampedTo(_latest);
    final DinnerCircle? had = _circles[got.id];
    if (had == null) {
      // New: an invitation from a friend who is a member.
      final CircleInvite? invite = got.invited[_me];
      if (invite == null ||
          got.hasMember(_me) ||
          !got.hasMember(from) ||
          !host.isFriend(from) ||
          invite.at <= (_declined[got.id] ?? -1) ||
          invite.at <= (got.gone[_me] ?? -1)) {
        return;
      }
      _circles[got.id] = got;
      await _save();
      await host.notify(
        RuntimeSystemNotification(
          id: 'circle-${got.id}',
          title: t('Zaproszenie do kółka: {name}', {'name': got.name}),
          body: t('Od {name}. Dołączasz?', {'name': host.nameOf(from)}),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'circle:${got.id}',
        ),
      );
      return;
    }
    if (!had.hasMember(from) && !got.hasMember(from)) {
      return;
    }
    final DinnerCircle merged = DinnerCircle.merge(had, got);
    if (!merged.hasMember(_me) && !merged.isInvited(_me)) {
      // Not in it any more (this person left or declined elsewhere).
      _circles.remove(had.id);
      await _save();
      return;
    }
    _circles[had.id] = merged.prunedBefore(
      _now() - kCircleDinnerKeep.inMilliseconds,
    );
    await _save();
  }

  /// [from] answered the invitation: joins at the end of the queue, or is
  /// out.
  Future<void> _onAnswer(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final Object? yes = payload['y'];
    final Object? at = payload['t'];
    final DinnerCircle? c = id is String ? _circles[id] : null;
    final CircleInvite? invite = c?.invited[from];
    if (c == null || invite == null || yes is! bool || at is! int) {
      return;
    }
    final int when = max(invite.at + 1, min(at, _latest));
    final Object? n = payload['n'];
    final String name = invite.name.isNotEmpty
        ? invite.name
        : n is String && n.trim().isNotEmpty
        ? (n.trim().length > 60 ? n.trim().substring(0, 60) : n.trim())
        : host.nameOf(from);
    final Map<String, CircleInvite> invited = <String, CircleInvite>{
      ...c.invited,
    }..remove(from);
    final DinnerCircle updated = yes
        ? c.copyWith(
            members: <CircleMember>[
              ...c.members,
              CircleMember(from, name, pos: when, at: when),
            ],
            invited: invited,
          )
        : c.copyWith(
            invited: invited,
            gone: <String, int>{...c.gone, from: when},
          );
    _circles[c.id] = updated;
    await _save();
    if (!c.hasMember(_me)) {
      return; // another invited person: nothing to tell
    }
    if (yes) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'circle-join-${c.id}-$from',
          title: t('{name} dołącza do kółka', {'name': name}),
          body: c.name,
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'circle:${c.id}',
        ),
      );
    } else if (invite.by == _me) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'circle-decline-${c.id}-$from',
          title: t('{name} nie dołączy do kółka', {'name': name}),
          body: c.name,
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'circle:${c.id}',
        ),
      );
    }
  }

  /// [from] left: out of the queue, which is worked out again.
  Future<void> _onLeave(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final Object? at = payload['t'];
    final DinnerCircle? c = id is String ? _circles[id] : null;
    final CircleMember? m = c?.member(from);
    if (c == null || m == null || at is! int) {
      return;
    }
    final int when = max(m.at + 1, min(at, _latest));
    _circles[c.id] = c.copyWith(
      members: <CircleMember>[
        for (final CircleMember x in c.members)
          if (x.address != from) x,
      ],
      gone: <String, int>{...c.gone, from: when},
    );
    if (swapRequests[c.id] == from) {
      swapRequests.remove(c.id);
    }
    await _save();
    if (c.hasMember(_me)) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'circle-leave-${c.id}-$from',
          title: t('{name} opuszcza kółko', {'name': m.name}),
          body: t('{circle}: kolejka gotowania ułożyła się na nowo.', {
            'circle': c.name,
          }),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'circle:${c.id}',
        ),
      );
    }
  }

  Future<void> _onChat(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final Object? day = payload['d'];
    final Object? mid = payload['m'];
    final Object? text = payload['x'];
    final Object? at = payload['t'];
    final DinnerCircle? c = id is String ? _circles[id] : null;
    if (c == null ||
        !c.hasMember(from) ||
        !c.hasMember(_me) ||
        !DinnerCircle.isDayKey(day) ||
        !isThreadMessageId(mid) ||
        text is! String ||
        at is! int) {
      return;
    }
    final String? clean = cleanThreadText(text);
    if (clean == null) {
      return;
    }
    final String key = '${c.id}|$day';
    if (!_threads.add(
      key,
      MeetThreadMessage(
        id: mid as String,
        from: from,
        text: clean,
        at: min(at, _latest),
      ),
    )) {
      return;
    }
    await _save();
    final String name = c.nameIn(from) ?? host.nameOf(from);
    await host.notify(
      RuntimeSystemNotification(
        id: 'circle-chat-${c.id}-$mid',
        title: t('{name} · {circle}', {'name': name, 'circle': c.name}),
        body: clean,
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'circle-chat:$key',
      ),
    );
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Dinner circle: to $to: $error');
    }
  }
}

/// The cook's count in a few words: "5 osób · Bez glutenu: 1 · Może: 1 ·
/// Bez odpowiedzi: 2".
String circleCountText(CircleHeadcount h) => <String>[
  tn(h.people, one: '{n} osoba', few: '{n} osoby', many: '{n} osób'),
  for (final CircleDiet d in CircleDiet.values)
    if ((h.diets[d] ?? 0) > 0) '${d.label}: ${h.diets[d]}',
  if (h.maybe > 0) t('Może: {n}', {'n': h.maybe}),
  if (h.unanswered > 0) t('Bez odpowiedzi: {n}', {'n': h.unanswered}),
].join(' · ');
