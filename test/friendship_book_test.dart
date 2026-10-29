import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Who is a friend is decided in one place: the friendship book. These
/// check its rules on their own, and that the account's devices end up
/// agreeing whatever order things happen in.

String _a(String raw) => PeerShareCodec.normalizeAddress(raw);

final String _fred = _a('200::f');
final String _gosia = _a('200::9');

FriendshipTick _at(int millis, [String device = 'phone']) =>
    FriendshipTick(millis, device);

FriendProfile _named(FriendProfile base, String name) =>
    base.copyWith(displayName: name);

/// A friendship with [address] made on [book] at [millis]: invited, then
/// their acceptance.
FriendshipBook _befriend(
  FriendshipBook book,
  String address,
  int millis, [
  String device = 'phone',
]) => book
    .invite(address, (FriendProfile base) => base)
    .admit(
      address,
      FriendshipEvidence.theyAcceptedMine,
      _at(millis, device),
      shape: (FriendProfile base) => _named(base, 'Fred'),
    );

void main() {
  group('the state machine', () {
    test('only an invitation answered makes a friend', () {
      FriendshipBook book = FriendshipBook.empty;
      // An acceptance nobody here asked for, a copy of the account's own
      // device with nothing newer: only the latter (an own record).
      expect(
        identical(
          book.admit(_fred, FriendshipEvidence.theyAcceptedMine, _at(10)),
          book,
        ),
        isTrue,
      );
      expect(
        identical(
          book.admit(_fred, FriendshipEvidence.iAcceptedTheirs, _at(10)),
          book,
        ),
        isTrue,
      );
      expect(book.meaningOfAccept(_fred), AcceptMeaning.invitation);

      book = book.invite(_fred, (FriendProfile base) => base);
      expect(book.standingOf(_fred), FriendshipStanding.requestedOut);
      expect(book.meaningOfAccept(_fred), AcceptMeaning.admits);
      book = book.admit(_fred, FriendshipEvidence.theyAcceptedMine, _at(20));
      expect(book.standingOf(_fred), FriendshipStanding.friend);
      expect(book.recordOf(_fred)!.mark, FriendshipMark.friend);
      expect(book.meaningOfAccept(_fred), AcceptMeaning.repeated);

      FriendshipBook other = FriendshipBook.empty.invitedBy(
        _gosia,
        (FriendProfile base) => _named(base, 'Gosia'),
      );
      expect(other.standingOf(_gosia), FriendshipStanding.requestedIn);
      expect(other.meaningOfAccept(_gosia), AcceptMeaning.nothing);
      other = other.admit(_gosia, FriendshipEvidence.iAcceptedTheirs, _at(5));
      expect(
        other.profileOf(_gosia)!.status,
        FriendRelationshipStatus.accepted,
      );
      expect(other.profileOf(_gosia)!.displayName, 'Gosia');
    });

    test(
      'a removed friend stays removed until a new invitation is answered',
      () {
        FriendshipBook book = _befriend(FriendshipBook.empty, _fred, 10);
        book = book.remove(_fred, _at(20), dropPending: true);
        expect(book.profileOf(_fred), isNull);
        expect(book.standingOf(_fred), FriendshipStanding.removed);
        expect(book.removedAt(_fred), 20);
        // Their old acceptance again (a replay, a frame from the locked
        // service): nothing, not even an invitation.
        expect(book.meaningOfAccept(_fred), AcceptMeaning.nothing);
        expect(
          identical(
            book.admit(_fred, FriendshipEvidence.theyAcceptedMine, _at(30)),
            book,
          ),
          isTrue,
        );
        // An own device's copy that still lists them (older than the
        // removal): nothing.
        expect(
          identical(
            book.merge(
              _fred,
              const FriendshipRecord(
                FriendshipMark.friend,
                FriendshipStamp(Hlc(15, 0), 'desktop'),
              ),
              _at(30),
            ),
            book,
          ),
          isTrue,
        );
        // Presence, a profile, a preview: they edit entries, and there is
        // none.
        expect(
          identical(
            book.edit(_fred, (FriendProfile f) => _named(f, 'Fred')),
            book,
          ),
          isTrue,
        );
        // Their new invitation shows as one.
        book = book.invitedBy(_fred, (FriendProfile base) => base);
        expect(book.standingOf(_fred), FriendshipStanding.requestedIn);
        expect(book.removedAt(_fred), 20, reason: 'still removed until then');
        book = book.admit(_fred, FriendshipEvidence.iAcceptedTheirs, _at(40));
        expect(book.standingOf(_fred), FriendshipStanding.friend);
        expect(book.removedAt(_fred), isNull);
      },
    );

    test('a friendship made in the same millisecond as the removal comes '
        'after it', () {
      FriendshipBook book = _befriend(FriendshipBook.empty, _fred, 10);
      book = book.remove(_fred, _at(50));
      book = _befriend(book, _fred, 50);
      expect(book.standingOf(_fred), FriendshipStanding.friend);
      expect(book.recordOf(_fred)!.stamp.hlc, const Hlc(50, 1));
    });

    test('an edit never changes the standing or adds anyone', () {
      FriendshipBook book = FriendshipBook.empty.invitedBy(
        _gosia,
        (FriendProfile base) => base,
      );
      book = book.edit(
        _gosia,
        (FriendProfile f) => f.copyWith(
          status: FriendRelationshipStatus.accepted,
          displayName: 'Gosia',
        ),
      );
      expect(
        book.profileOf(_gosia)!.status,
        FriendRelationshipStatus.pendingIncoming,
      );
      expect(book.profileOf(_gosia)!.displayName, 'Gosia');
      book = book.editAll(
        (FriendProfile f) =>
            f.copyWith(status: FriendRelationshipStatus.blocked),
      );
      expect(
        book.profileOf(_gosia)!.status,
        FriendRelationshipStatus.pendingIncoming,
      );
      expect(book.records, isEmpty);
      expect(
        () => book.profiles[_fred] = FriendProfile(
          address: _fred,
          status: FriendRelationshipStatus.accepted,
        ),
        throwsUnsupportedError,
      );
    });

    test('a block and an unblock are records too', () {
      FriendshipBook book = _befriend(FriendshipBook.empty, _fred, 10);
      book = book.block(_fred, _at(20));
      expect(book.standingOf(_fred), FriendshipStanding.blocked);
      expect(book.meaningOfAccept(_fred), AcceptMeaning.nothing);
      book = book.unblock(_fred, _at(30));
      expect(book.profileOf(_fred)!.status, FriendRelationshipStatus.none);
      expect(book.recordOf(_fred)!.mark, FriendshipMark.none);
      expect(book.meaningOfAccept(_fred), AcceptMeaning.invitation);
    });

    test('a record dated far ahead is refused', () {
      final FriendshipBook book = FriendshipBook.empty.merge(
        _fred,
        FriendshipRecord(
          FriendshipMark.friend,
          FriendshipStamp(
            Hlc(1000 + kMaxClockSkew.inMilliseconds + 1, 0),
            'desktop',
          ),
        ),
        _at(1000),
      );
      expect(book.profileOf(_fred), isNull);
    });

    test('records go to text and back; the oldest removals are forgotten '
        'past the limit', () {
      FriendshipBook book = _befriend(FriendshipBook.empty, _fred, 10);
      book = book.remove(_gosia, _at(20));
      final Object? json = jsonDecode(
        jsonEncode(friendshipRecordsToJson(book.records)),
      );
      expect(friendshipRecordsFromJson(json), book.records);
      final FriendshipBook again = FriendshipBook.restore(
        profiles: book.profiles,
        records: friendshipRecordsFromJson(json),
      );
      expect(again.records, book.records);
      expect(again.clock, book.clock);

      FriendshipBook many = FriendshipBook.empty;
      for (int i = 0; i < kMaxRemovedFriends + 5; i++) {
        many = many.remove(_a('200::${(i + 1).toRadixString(16)}'), _at(i + 1));
      }
      expect(many.records, hasLength(kMaxRemovedFriends));
      expect(many.removedAt(_a('200::1')), isNull, reason: 'the oldest went');
    });

    test('what test builds kept before records loads as records', () {
      final Map<String, FriendshipRecord> records = legacyFriendshipRecords(
        removed: <String, int>{_gosia: 30, _fred: 5},
        since: <String, int>{_fred: 20},
        profiles: <String, FriendProfile>{
          _fred: FriendProfile(
            address: _fred,
            status: FriendRelationshipStatus.accepted,
          ),
        },
      );
      expect(records[_gosia]!.mark, FriendshipMark.removed);
      expect(records[_gosia]!.stamp.hlc.millis, 30);
      expect(records[_fred]!.mark, FriendshipMark.friend);
      expect(records[_fred]!.stamp.hlc.millis, 20);
      final FriendshipBook book = FriendshipBook.restore(
        profiles: <String, FriendProfile>{
          _fred: FriendProfile(
            address: _fred,
            status: FriendRelationshipStatus.accepted,
          ),
        },
        records: records,
      );
      expect(book.standingOf(_fred), FriendshipStanding.friend);
      expect(book.standingOf(_gosia), FriendshipStanding.removed);
      expect(book.clock, const Hlc(30, 0));
    });

    test('a friend kept without a time loses to any removal record', () {
      // Friends from before records: older than anything.
      final FriendshipBook book = FriendshipBook.restore(
        profiles: <String, FriendProfile>{
          _fred: FriendProfile(
            address: _fred,
            status: FriendRelationshipStatus.accepted,
          ),
        },
      );
      expect(book.recordOf(_fred)!.stamp, FriendshipStamp.zero);
      final FriendshipBook removed = book.merge(
        _fred,
        const FriendshipRecord(
          FriendshipMark.removed,
          FriendshipStamp(Hlc(1, 0), ''),
        ),
        _at(10),
      );
      expect(removed.profileOf(_fred), isNull);
    });
  });

  group('two devices', () {
    test('a removal on one and a friendship made again on the other, '
        'concurrently: the later wins on both', () {
      FriendshipBook phone = _befriend(FriendshipBook.empty, _fred, 10);
      FriendshipBook desktop = phone.mergeAll(
        FriendshipBook.empty,
        _at(10, 'desktop'),
      );
      desktop = FriendshipBook.empty.mergeAll(phone, _at(11, 'desktop'));
      expect(desktop.standingOf(_fred), FriendshipStanding.friend);

      // Unaware of each other: the phone removes at 100; the desktop
      // (its clock behind) removes and invites again, answered at 90.
      phone = phone.remove(_fred, _at(100));
      desktop = desktop.remove(_fred, _at(80, 'desktop'), dropPending: true);
      desktop = _befriend(desktop, _fred, 90, 'desktop');
      expect(desktop.standingOf(_fred), FriendshipStanding.friend);

      final FriendshipBook phoneAfter = phone.mergeAll(desktop, _at(120));
      final FriendshipBook desktopAfter = desktop.mergeAll(
        phone,
        _at(95, 'desktop'),
      );
      expect(phoneAfter.records, desktopAfter.records);
      expect(phoneAfter.standingOf(_fred), FriendshipStanding.removed);
      expect(desktopAfter.standingOf(_fred), FriendshipStanding.removed);

      // Once the desktop knows of the removal, a friendship it makes is
      // later than it, whatever its clock says.
      FriendshipBook desktopAgain = _befriend(
        desktopAfter,
        _fred,
        96,
        'desktop',
      );
      expect(desktopAgain.recordOf(_fred)!.stamp.hlc, const Hlc(100, 1));
      final FriendshipBook phoneAgain = phoneAfter.mergeAll(
        desktopAgain,
        _at(130),
      );
      expect(phoneAgain.standingOf(_fred), FriendshipStanding.friend);
      expect(phoneAgain.profileOf(_fred)!.displayName, 'Fred');
      desktopAgain = desktopAgain.mergeAll(phoneAgain, _at(131, 'desktop'));
      expect(phoneAgain.records, desktopAgain.records);
    });
  });

  group('random histories on the account\'s devices', () {
    for (final int seed in <int>[1, 2, 3, 4, 5, 6, 7, 8]) {
      test('converge, and removed stays removed unless invited again after '
          '(seed $seed)', () {
        _History(Random(seed)).run();
      });
    }
  });
}

/// One own device in a random history: its book and how far its clock is
/// off.
final class _Device {
  _Device(this.name, this.skew);

  final String name;
  final int skew;
  FriendshipBook book = FriendshipBook.empty;
}

/// A record some device made, and how.
typedef _Issued = ({String address, FriendshipRecord record, String how});

/// Random operations across 2–3 own devices: the user's actions, frames from
/// the peers (acceptances, invitations, removals, replays of old ones,
/// presence and profiles) and syncs of some records in random order; at the
/// end every device syncs with every other.
final class _History {
  _History(this.random)
    : devices = <_Device>[
        for (int i = 0; i < 2 + random.nextInt(2); i++)
          _Device('d$i', random.nextInt(101) - 50),
      ];

  final Random random;
  final List<_Device> devices;
  final List<String> peers = <String>[
    for (int i = 1; i <= 3; i++) _a('200::$i'),
  ];
  final List<_Issued> issued = <_Issued>[];
  int now = 1000;

  FriendshipTick _tick(_Device d) => FriendshipTick(now + d.skew, d.name);

  /// [change] on [d]'s book; what it newly recorded is noted as made [how].
  void _on(
    _Device d,
    String how,
    FriendshipBook Function(FriendshipBook) change,
  ) {
    final FriendshipBook before = d.book;
    d.book = change(before);
    for (final String p in peers) {
      final FriendshipRecord? r = d.book.recordOf(p);
      if (r != null && r != before.recordOf(p) && r.stamp.device == d.name) {
        issued.add((address: p, record: r, how: how));
      }
    }
  }

  void _sync(_Device from, _Device to, {bool all = false}) {
    final List<MapEntry<String, FriendshipRecord>> records =
        from.book.records.entries.toList()..shuffle(random);
    for (final MapEntry<String, FriendshipRecord> e in records) {
      if (!all && random.nextBool()) {
        continue;
      }
      final FriendProfile? theirs = from.book.profileOf(e.key);
      to.book = to.book.merge(
        e.key,
        e.value,
        _tick(to),
        shape: theirs == null ? null : (FriendProfile base) => base,
      );
    }
  }

  void _step() {
    now += random.nextInt(4);
    final _Device d = devices[random.nextInt(devices.length)];
    final String p = peers[random.nextInt(peers.length)];
    final FriendshipStanding before = d.book.standingOf(p);
    switch (random.nextInt(12)) {
      case 0:
        _on(d, 'user removes', (b) => b.remove(p, _tick(d), dropPending: true));
      case 1:
        _on(d, 'user invites', (b) => b.invite(p, (FriendProfile f) => f));
      case 2:
        _on(
          d,
          'user accepts',
          (b) => b.admit(p, FriendshipEvidence.iAcceptedTheirs, _tick(d)),
        );
      case 3 || 4:
        // Their acceptance, maybe an old one replayed (the queue kept for
        // the app's return, the locked service's hand-over).
        _on(d, 'accept frame', (b) {
          switch (b.meaningOfAccept(p)) {
            case AcceptMeaning.admits:
              return b.admit(p, FriendshipEvidence.theyAcceptedMine, _tick(d));
            case AcceptMeaning.repeated:
              return b.edit(p, (FriendProfile f) => f);
            case AcceptMeaning.invitation:
              return b.invitedBy(p, (FriendProfile f) => f);
            case AcceptMeaning.nothing:
              return b;
          }
        });
        if (before == FriendshipStanding.removed) {
          expect(d.book.standingOf(p), FriendshipStanding.removed);
        }
      case 5:
        // Their invitation.
        _on(
          d,
          'invitation frame',
          (b) => b.standingOf(p) == FriendshipStanding.requestedOut
              ? b.admit(p, FriendshipEvidence.bothInvited, _tick(d))
              : b.invitedBy(p, (FriendProfile f) => f),
        );
      case 6:
        // They removed this person.
        _on(
          d,
          'they removed',
          (b) => b.standingOf(p) == FriendshipStanding.friend
              ? b.remove(p, _tick(d))
              : b.withdraw(p),
        );
      case 7:
        // Presence, a profile, a message: never a standing.
        _on(
          d,
          'presence',
          (b) => b.edit(
            p,
            (FriendProfile f) => f.copyWith(
              displayName: 'P${random.nextInt(9)}',
              status: FriendRelationshipStatus.accepted,
              isOnline: random.nextBool(),
            ),
          ),
        );
        expect(d.book.standingOf(p), before);
      case 8:
        _on(d, 'block', (b) => b.block(p, _tick(d)));
      case 9:
        _on(d, 'unblock', (b) => b.unblock(p, _tick(d)));
      case 10 || 11:
        final _Device other = devices[random.nextInt(devices.length)];
        if (!identical(other, d)) {
          _sync(other, d);
        }
    }
  }

  void run() {
    for (int i = 0; i < 400; i++) {
      _step();
    }
    // Everyone syncs with everyone until nothing changes.
    bool changed = true;
    int rounds = 0;
    while (changed) {
      changed = false;
      rounds++;
      now += 5;
      for (final _Device to in devices) {
        for (final _Device from in devices) {
          if (identical(from, to)) {
            continue;
          }
          final FriendshipBook before = to.book;
          _sync(from, to, all: true);
          if (!identical(before, to.book)) {
            changed = true;
          }
        }
      }
      expect(rounds, lessThan(10), reason: 'syncing settles');
    }
    final Map<String, FriendshipRecord> agreed = devices.first.book.records;
    for (final _Device d in devices) {
      expect(d.book.records, agreed, reason: '${d.name} agrees');
      for (final String p in peers) {
        final FriendRelationshipStatus? status = d.book.profileOf(p)?.status;
        final FriendRelationshipStatus? first = devices.first.book
            .profileOf(p)
            ?.status;
        bool settled(FriendRelationshipStatus? s) =>
            s == FriendRelationshipStatus.accepted ||
            s == FriendRelationshipStatus.blocked;
        expect(settled(status), settled(first), reason: '$p on ${d.name}');
        if (settled(status)) {
          expect(status, first);
        }
      }
    }
    for (final String p in peers) {
      final List<_Issued> mine = issued
          .where((_Issued i) => i.address == p)
          .toList();
      final FriendshipRecord? agreedRecord = agreed[p];
      if (mine.isEmpty) {
        expect(agreedRecord, isNull);
        continue;
      }
      // The latest record any device made wins everywhere.
      final _Issued latest = mine.reduce(
        (_Issued a, _Issued b) => b.record.beats(a.record) ? b : a,
      );
      expect(agreedRecord, latest.record, reason: p);
      // Only an invitation answered ever made a friend.
      for (final _Issued i in mine) {
        if (i.record.mark == FriendshipMark.friend) {
          expect(<String>[
            'user accepts',
            'accept frame',
            'invitation frame',
          ], contains(i.how));
        }
      }
      // A friend at the end: that friendship is later than every removal.
      if (agreedRecord!.mark == FriendshipMark.friend) {
        for (final _Issued i in mine) {
          if (i.record.mark == FriendshipMark.removed) {
            expect(
              agreedRecord.stamp.compareTo(i.record.stamp),
              greaterThan(0),
            );
          }
        }
      }
    }
  }
}
