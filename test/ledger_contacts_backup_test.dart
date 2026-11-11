import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/contacts_backup.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// The backup of friends and groups friends keep in the account's private
// space: saved at every size the friends-list import allows (one entry up
// to some 240 friends, a set of parts above), read back whole on a new
// phone from a friend's copy only, never two backups mixed, the last whole
// one when a newer did not all arrive; and the log it lives in started
// over now and then, so a friend holds a bounded amount of it however
// often the list changes.

final class _Linked extends MemorySignalTransport {
  _Linked(this.address);

  static final Map<String, _Linked> nodes = <String, _Linked>{};
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null && nodes[address] == this) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<void> _settle([int rounds = 80]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Waits (up to [rounds] short steps) until [done].
Future<void> _until(bool Function() done, {int rounds = 2000}) async {
  for (int i = 0; i < rounds && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final String _author = _a('200::a1');
final String _holder = _a('200::b');
final String _fresh = _a('200::a9');

Future<LedgerNode> _node(
  String address, {
  required List<String> friends,
  MemoryLedgerDisk? disk,
}) async {
  final _Linked t = _Linked(address);
  _Linked.nodes[address] = t;
  await t.start();
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk ?? MemoryLedgerDisk(),
    friendAddresses: () => friends,
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    syncInterval: Duration.zero,
  );
  addTearDown(n.stop);
  await n.start();
  return n;
}

String _hex4(int v) => (v % 65536).toRadixString(16).padLeft(4, '0');

/// A friend's mesh address in the backup (full length, as the app's).
String _friend(int i) =>
    '201:${_hex4(i)}:5a3c:9e01:${_hex4(i * 7)}:77f2:${_hex4(i * 13)}:c0de';

/// A backup of [friends] friends shaped like the app's
/// (`contactsBackupOf`): names, nicknames, a record each (the device's id
/// as long as the app's), a group per 50. About as big per friend as the
/// app's: 250 friends no longer fit one entry.
Map<String, dynamic> _snapshot(int friends, {String renamed = ''}) =>
    <String, dynamic>{
      'v': 1,
      'friends': <Map<String, dynamic>>[
        for (int i = 0; i < friends; i++)
          <String, dynamic>{
            'a': _friend(i),
            'n': i == 7 && renamed.isNotEmpty ? renamed : 'Imię Nazwisko $i',
            'k': 'ksywka $i',
          },
      ],
      'groups': <Map<String, dynamic>>[
        for (int g = 0; g < friends ~/ 50; g++)
          <String, dynamic>{
            'id': 'grupa-$g',
            'name': 'Grupa numer $g',
            'avatar': 'group_default',
            'by': _friend(g),
            'at': 1790000000000 + g,
            'm': <String>[for (int m = 0; m < 5; m++) _friend(g * 5 + m)],
          },
      ],
      'r': <String, dynamic>{
        for (int i = 0; i < friends; i++)
          _friend(i): <Object>[
            'f',
            1790000000000 + i,
            'Qm${_hex4(i)}Zx${'k' * 35}=',
          ],
      },
    };

String _private(LedgerNode n) => accountSpace('private', n.account);

/// The account's author device and a friend who keeps its copy.
Future<(LedgerNode, LedgerNode, MemoryLedgerDisk)> _authorAndHolder() async {
  _Linked.nodes.clear();
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  final LedgerNode author = await _node(
    _author,
    friends: <String>[_holder],
    disk: disk,
  );
  final LedgerNode holder = await _node(_holder, friends: <String>[_author]);
  await _until(() => holder.accountOfAddress(_author) != null);
  return (author, holder, disk);
}

/// A new phone of [author]'s account that knows only [_holder]: the author
/// is offline.
Future<LedgerNode> _restoreOnNewPhone(
  LedgerNode author,
  MemoryLedgerDisk authorDisk,
) async {
  _Linked.nodes.remove(_author);
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  await LedgerIdentity.adoptAccount(
    disk,
    (await LedgerIdentity.loadOrCreate(authorDisk)).accountKey!.seed,
  );
  return _node(_fresh, friends: <String>[_holder], disk: disk);
}

/// Whether [n] holds what [author]'s private log holds.
bool _caughtUp(LedgerNode n, LedgerNode author) =>
    n.store.headOf(_private(author), author.author.writer) ==
    author.store.headOf(_private(author), author.author.writer);

void main() {
  setUp(() {
    ContactsBackupNotice.instance.saved();
    LedgerNode.rebaseDropDelay = const Duration(milliseconds: 20);
  });
  tearDown(() {
    LedgerNode.rebaseDropDelay = const Duration(seconds: 30);
  });

  for (final int friends in <int>[250, 300, 1000, 5000]) {
    test('$friends friends are saved with a friend and come back whole on a '
        'new phone from that friend alone', () async {
      final (LedgerNode author, LedgerNode holder, MemoryLedgerDisk disk) =
          await _authorAndHolder();
      final Map<String, dynamic> snapshot = _snapshot(friends);
      expect(await author.publishContacts(snapshot), isTrue);
      expect(ContactsBackupNotice.instance.failing, isFalse);
      // Every entry fits, however many friends there are.
      final List<LogEntry> written = author.store.entries(_private(author));
      expect(
        written.every((LogEntry e) => e.encodedLength <= kMaxEntryBytes),
        isTrue,
      );
      // Too big for one entry (1.16.4 wrote nothing at all from here on).
      expect(contactsJsonBytes(snapshot), greaterThan(kContactsWholeBytes));
      expect(
        written.map((LogEntry e) => e.kind),
        containsAll(<String>[kContactsPartKind, kContactsSetKind]),
      );
      await _until(() => _caughtUp(holder, author));
      expect(_caughtUp(holder, author), isTrue);
      // The friend keeps it sealed.
      expect(
        holder.store
            .entries(_private(author))
            .every((LogEntry e) => isSealed(e.body)),
        isTrue,
      );

      final LedgerNode phone = await _restoreOnNewPhone(author, disk);
      await _until(() => phone.latestContacts() != null);
      expect(jsonEncode(phone.latestContacts()), jsonEncode(snapshot));
    }, timeout: const Timeout(Duration(minutes: 4)));
  }

  test('a change writes the parts it touches and a new set; a restore takes '
      'the newest set whole, or the one before when the newest did not all '
      'arrive, never a mix', () async {
    final (LedgerNode author, LedgerNode holder, MemoryLedgerDisk disk) =
        await _authorAndHolder();
    final Map<String, dynamic> first = _snapshot(1000);
    final Map<String, dynamic> second = _snapshot(1000, renamed: 'Nowe Imię');
    await author.publishContacts(first);
    final int afterFirst = author.store.headOf(
      _private(author),
      author.author.writer,
    );
    await author.publishContacts(second);
    final List<LogEntry> change = author.store.entriesAfter(
      _private(author),
      author.author.writer,
      afterFirst,
    );
    // A rename: one part (or two, where its end moved) and the set.
    expect(change.last.kind, kContactsSetKind);
    expect(change.length, lessThanOrEqualTo(3));
    final int whole = author.store.heldBytes(
      _private(author),
      author.author.writer,
    );
    final int changed = change.fold<int>(
      0,
      (int sum, LogEntry e) => sum + e.encodedLength,
    );
    expect(changed * 5, lessThan(whole));
    // ignore: avoid_print
    print(
      'a rename with 1,000 friends writes ${changed ~/ 1024} KiB; '
      'the whole backup is ${(whole - changed) ~/ 1024} KiB',
    );
    expect(jsonEncode(author.latestContacts()), jsonEncode(second));

    // A friend that got only the parts of the change, not its set.
    await _until(() => _caughtUp(holder, author));
    _Linked.nodes.remove(_author);
    final MemoryLedgerDisk freshDisk = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(
      freshDisk,
      (await LedgerIdentity.loadOrCreate(disk)).accountKey!.seed,
    );
    final LedgerNode phone = await _node(
      _fresh,
      friends: const <String>[],
      disk: freshDisk,
    );
    for (final LogEntry e in holder.store.entriesAfter(
      _private(author),
      author.author.writer,
      0,
    )) {
      if (e.kind == kContactsSetKind && e.seq > afterFirst) {
        break; // the newest set never came
      }
      await phone.store.ingestJson(e.toCertifiedJson());
    }
    await _until(() => phone.latestContacts() != null);
    await _settle(20);
    expect(jsonEncode(phone.latestContacts()), jsonEncode(first));

    // The set comes after all: the newest, whole.
    for (final LogEntry e in change) {
      await phone.store.ingestJson(e.toCertifiedJson());
    }
    await _until(
      () => jsonEncode(phone.latestContacts()) == jsonEncode(second),
    );
    expect(jsonEncode(phone.latestContacts()), jsonEncode(second));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a set whose parts do not add up to it is never taken', () {
    final Map<String, dynamic> one = _snapshot(1000);
    final Map<String, dynamic> two = _snapshot(1000, renamed: 'Ktoś Inny');
    final ContactsSplit a = splitContacts(one);
    final ContactsSplit b = splitContacts(two);
    final Map<String, dynamic> set = contactsSetOf(a, <int>[
      for (int i = 0; i < a.parts.length; i++) i + 1,
    ]);
    expect(
      jsonEncode(assembleContacts(set, (int seq) => a.parts[seq - 1])),
      jsonEncode(one),
    );
    // Parts of the other backup, where they differ: refused.
    expect(
      assembleContacts(
        set,
        (int seq) => seq - 1 < b.parts.length ? b.parts[seq - 1] : null,
      ),
      isNull,
    );
    // A part missing: refused.
    expect(
      assembleContacts(set, (int seq) => seq == 2 ? null : a.parts[seq - 1]),
      isNull,
    );
  });

  test('a backup that cannot be saved is reported, not only logged, and the '
      'report goes when one is saved', () async {
    final (LedgerNode author, LedgerNode _, MemoryLedgerDisk _) =
        await _authorAndHolder();
    final Map<String, dynamic> huge = _snapshot(300)
      ..['groups'] = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'ogromna',
          'name': 'x' * (kContactsPartBytes + 10),
          'm': <String>[],
        },
      ];
    expect(await author.publishContacts(huge), isFalse);
    expect(ContactsBackupNotice.instance.failing, isTrue);
    expect(await author.publishContacts(_snapshot(300)), isTrue);
    expect(ContactsBackupNotice.instance.failing, isFalse);
  });

  test('a log of 1,000 superseded backups shrinks to the bound at the '
      'author and at a friend; a new phone gets everything still valid from '
      'the friend\'s cut copy', () async {
    final (LedgerNode author, LedgerNode holder, MemoryLedgerDisk disk) =
        await _authorAndHolder();
    final String space = _private(author);
    final String writer = author.author.writer;
    // What 1.16.4 wrote: a whole backup at every change.
    await author.publishForOwnDevices(kContactRemovedKind, <String, dynamic>{
      'a': _friend(999),
    }, spaceKind: 'private');
    final int removedAt = author.store.entries(space).last.hlc.millis;
    for (int i = 0; i < 1000; i++) {
      await author.publish(
        kContactsKind,
        await sealForSelf(
          _snapshot(50, renamed: 'Wersja $i'),
          author.identity.selfKey!,
          account: author.account,
        ),
        spaceKind: 'private',
      );
    }
    await _until(() => _caughtUp(holder, author), rounds: 6000);
    final int before = holder.store.heldBytes(space, writer);

    final Map<String, dynamic> now = _snapshot(50, renamed: 'Teraz');
    expect(await author.publishContacts(now), isTrue);
    await _until(
      () =>
          _caughtUp(holder, author) &&
          holder.store.baseOf(space, writer).base ==
              author.store.baseOf(space, writer).base,
    );
    final int atAuthor = author.store.heldBytes(space, writer);
    final int atHolder = holder.store.heldBytes(space, writer);
    final int one = author.store.entries(space).last.encodedLength;
    // A checkpoint, the removal carried and the backup.
    expect(author.store.entries(space).length, 3);
    expect(atHolder, atAuthor);
    expect(atHolder, lessThan(one + kPrivateLogSlackBytes));
    expect(before, greaterThan(1000 * one ~/ 2));
    // ignore: avoid_print
    print(
      'private log of a 50-friend author at a friend: '
      '1,000 changes before ${before ~/ 1024} KiB, after ${atHolder ~/ 1024} '
      'KiB (one backup ${one ~/ 1024} KiB)',
    );

    final LedgerNode phone = await _restoreOnNewPhone(author, disk);
    await _until(() => phone.latestContacts() != null);
    expect(jsonEncode(phone.latestContacts()), jsonEncode(now));
    await _until(() => phone.contactRemovals().isNotEmpty);
    expect(phone.contactRemovals(), <String, int>{_a(_friend(999)): removedAt});
    // The phone holds the log from the checkpoint, like the friend.
    expect(
      phone.store.baseOf(space, writer).base,
      holder.store.baseOf(space, writer).base,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the bound holds over many changes, for a typical and a heavy '
      'author', () async {
    for (final int friends in <int>[50, 2000]) {
      final (LedgerNode author, LedgerNode holder, MemoryLedgerDisk _) =
          await _authorAndHolder();
      final String space = _private(author);
      final String writer = author.author.writer;
      int most = 0;
      int valid = 0;
      for (int i = 0; i < 40; i++) {
        await author.publishContacts(_snapshot(friends, renamed: 'Zmiana $i'));
        await _until(() => _caughtUp(holder, author));
        await _settle(6);
        final int held = holder.store.heldBytes(space, writer);
        if (held > most) {
          most = held;
        }
      }
      for (final LogEntry e in author.store.entries(space)) {
        if (e.kind == kContactsKind || e.kind == kContactsPartKind) {
          valid += e.encodedLength;
        }
      }
      // ignore: avoid_print
      print(
        'private log of a $friends-friend author at a friend over 40 '
        'changes: at most ${most ~/ 1024} KiB',
      );
      // Today's whole backup, as much again of superseded ones, and what a
      // start over writes besides.
      final int bound =
          2 * (valid > kPrivateLogSlackBytes ? valid : kPrivateLogSlackBytes) +
          2 * kContactsWholeBytes;
      expect(most, lessThan(bound));
      await author.stop();
      await holder.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('a friend away across two start-overs catches up to the newest one '
      'and holds no more than the author', () async {
    final (LedgerNode author, LedgerNode holder, MemoryLedgerDisk _) =
        await _authorAndHolder();
    final String space = _private(author);
    final String writer = author.author.writer;
    await author.publishContacts(_snapshot(50));
    await _until(() => _caughtUp(holder, author));
    _Linked.nodes.remove(_holder);
    int starts = 0;
    final StreamSubscription<LogEntry> sub = author.store.added.listen((
      LogEntry e,
    ) {
      if (e.space == space && isLedgerCheckpoint(e)) {
        starts++;
      }
    });
    addTearDown(sub.cancel);
    for (int i = 0; starts < 2 && i < 200; i++) {
      await author.publishContacts(_snapshot(50, renamed: 'Zmiana $i'));
    }
    expect(starts, 2);
    final int authorBase = author.store.baseOf(space, writer).base;
    expect(holder.store.headOf(space, writer), lessThan(authorBase));

    _Linked.nodes[_holder] = holder.transport as _Linked;
    holder.greet(_author);
    author.greet(_holder);
    await _until(
      () =>
          _caughtUp(holder, author) &&
          holder.store.baseOf(space, writer).base == authorBase,
    );
    expect(holder.store.isForked(space, writer), isFalse);
    expect(holder.store.baseOf(space, writer).base, authorBase);
    expect(
      holder.store.heldBytes(space, writer),
      author.store.heldBytes(space, writer),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a removal another device wrote is dropped only once it was taken '
      'here', () async {
    final (LedgerNode author, LedgerNode holder, MemoryLedgerDisk disk) =
        await _authorAndHolder();
    final String space = _private(author);
    final String writer = author.author.writer;
    final MemoryLedgerDisk siblingDisk = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(
      siblingDisk,
      (await LedgerIdentity.loadOrCreate(disk)).accountKey!.seed,
    );
    final LedgerNode sibling = await _node(
      _fresh,
      friends: <String>[_holder],
      disk: siblingDisk,
    );
    final LogEntry? removal = await author.publishForOwnDevices(
      kContactRemovedKind,
      <String, dynamic>{'a': _friend(3)},
      spaceKind: 'private',
    );
    for (int i = 0; i < 30; i++) {
      await author.publishContacts(_snapshot(50, renamed: 'Zmiana $i'));
    }
    await _until(() => _caughtUp(sibling, author));
    await _settle(20);
    expect(author.store.baseOf(space, writer).base, greaterThan(0));
    // Not taken yet on the sibling: kept there.
    expect(sibling.store.baseOf(space, writer).base, 0);
    expect(sibling.store.entryById(space, removal!.id), isNotNull);
    await sibling.markOwnApplied(removal.id);
    await _until(() => sibling.store.baseOf(space, writer).base > 0);
    expect(
      sibling.store.baseOf(space, writer).base,
      author.store.baseOf(space, writer).base,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
