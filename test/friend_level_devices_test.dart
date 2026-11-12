// A friend's level is one setting of the account: set on any of its
// devices, it is the level on every device, the newest change winning, and
// each device acts on it (the audience keys it hands out, who holds a
// recovery piece) the same whichever device it was set on.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/recovery_circle_pick.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes);

  final String address;
  final Map<String, _Linked> nodes;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    // A device switched off ([_World.off]) neither sends nor receives.
    if (target != null && nodes[address] == this) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

String _a(String s) => PeerShareCodec.normalizeAddress(s);

final String a1 = _a('200::a1');
final String a2 = _a('200::a2');
final String a3 = _a('200::a3');
final String b = _a('200::b');
final String c = _a('200::c');

Future<void> _settle([int rounds = 200]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Hellos go at most once a second; this wait stands for the time between
/// two (in the app every 10 minutes and at every start).
Future<void> _later() =>
    Future<void>.delayed(const Duration(milliseconds: 1100));

/// Ada's devices and her friends, on one simulated mesh.
final class _World {
  final Map<String, _Linked> nodes = <String, _Linked>{};
  final Map<String, LedgerNode> live = <String, LedgerNode>{};
  final Map<String, MemoryLedgerDisk> disks = <String, MemoryLedgerDisk>{};

  Future<LedgerNode> make(
    String address,
    List<String> friends, {
    MemoryLedgerDisk? disk,
    int skewMs = 0,
  }) async {
    final _Linked t = nodes[address] = _Linked(address, nodes);
    await t.start();
    final MemoryLedgerDisk d = disks[address] =
        disk ?? disks[address] ?? MemoryLedgerDisk();
    final LedgerNode n = LedgerNode(
      transport: t,
      disk: d,
      friendAddresses: () => friends,
      bridges: BridgeBook(probe: (String _) async => null),
      localAddress: () => address,
      clock: HlcClock(
        wallClock: () => DateTime.now().millisecondsSinceEpoch + skewMs,
      ),
      syncInterval: Duration.zero,
      helloInterval: Duration.zero,
    );
    addTearDown(n.stop);
    await n.start();
    live[address] = n;
    return n;
  }

  /// Another device of the account of [first], at [address].
  Future<LedgerNode> device(
    String address,
    LedgerNode first,
    List<String> friends, {
    int skewMs = 0,
  }) async {
    final MemoryLedgerDisk d = disks[address] = MemoryLedgerDisk();
    final first0 = await LedgerIdentity.loadOrCreate(disks[_own(first)]!);
    await LedgerIdentity.adoptAccount(d, first0.accountKey!.seed);
    final LedgerNode n = await make(address, friends, disk: d, skewMs: skewMs);
    await n.rememberDeviceAddresses(<String>[_own(first)]);
    await _settle();
    expect(n.account, first.account);
    return n;
  }

  String _own(LedgerNode n) =>
      live.entries.firstWhere((MapEntry<String, LedgerNode> e) {
        return identical(e.value, n);
      }).key;

  /// [address] is switched off (away): nothing reaches it, nothing leaves.
  Future<void> off(String address) async {
    nodes.remove(address);
    await live.remove(address)?.stop();
  }

  /// Every device greets every other, twice (a hello and its answers).
  Future<void> meet() async {
    for (int i = 0; i < 2; i++) {
      await _later();
      for (final LedgerNode n in live.values.toList()) {
        await n.greetFriends();
      }
      await _settle(300);
    }
  }
}

List<String> _texts(LedgerNode node, String account) => <String>[
  for (final FeedPost p in buildFeed(node, nameOf: (String x) => x))
    if (p.account == account) p.text,
];

Future<void> _post(LedgerNode n, Audience audience, String text) async {
  await n.publish(
    kPostKind,
    await n.seal(audience, newPostBody(text, audience: audience)),
  );
  await _settle();
}

void main() {
  test('one device: a friend taken down to "Słaby znajomy" does not read a '
      'post for "Tylko przyjaciele" written after it', () async {
    final _World w = _World();
    final LedgerNode ada = await w.make(a1, <String>[b]);
    final LedgerNode bob = await w.make(b, <String>[a1]);
    await _settle();
    await ada.setLevel(b, FriendLevel.close);
    await ada.setLevel(b, FriendLevel.weak);
    await _post(ada, Audience.close, 'Tylko dla przyjaciół');
    await w.meet();
    expect(_texts(bob, ada.account), isNot(contains('Tylko dla przyjaciół')));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'a friend taken down on the phone is taken down on the computer too, '
    'and gets no key to what is written for "Tylko przyjaciele" after',
    () async {
      final _World w = _World();
      final LedgerNode phone = await w.make(a1, <String>[b]);
      final LedgerNode bob = await w.make(b, <String>[a1, a2]);
      await _settle();
      final LedgerNode computer = await w.device(a2, phone, <String>[b]);
      expect(phone.siblingAddresses, contains(a2));

      await phone.setLevel(b, FriendLevel.close);
      await w.meet();
      expect(computer.levelOf(b), FriendLevel.close, reason: 'a level travels');

      await phone.setLevel(b, FriendLevel.weak);
      await _settle();
      await _post(phone, Audience.close, 'Tylko dla przyjaciół');
      await w.meet();
      await _post(
        computer,
        Audience.close,
        'Z komputera, tylko dla przyjaciół',
      );
      await w.meet();
      expect(phone.levelOf(b), FriendLevel.weak);
      expect(computer.levelOf(b), FriendLevel.weak);
      expect(
        _texts(bob, phone.account),
        isNot(
          anyOf(
            contains('Tylko dla przyjaciół'),
            contains('Z komputera, tylko dla przyjaciół'),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('"Przyjaciel" taken off on the second device: the device that hands '
      'the recovery pieces out stops counting them as close', () async {
    final _World w = _World();
    final String x = _a('200::c1');
    final String y = _a('200::c2');
    final LedgerNode first = await w.make(a1, <String>[x, y]);
    final LedgerNode second = await w.device(a2, first, <String>[x, y]);
    await first.setLevel(x, FriendLevel.close);
    await first.setLevel(y, FriendLevel.close);
    await w.meet();
    expect(second.levelOf(x), FriendLevel.close, reason: 'taken once');

    await second.setLevel(x, FriendLevel.friend);
    await w.meet();
    final List<String> holders = pieceHolders(
      close: <String>[
        x,
        y,
      ].where((String a) => first.levelOf(a) == FriendLevel.close),
      account: first.account,
    );
    expect(first.levelOf(x), FriendLevel.friend);
    expect(holders, isNot(contains(x)));
    expect(holders, contains(y));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a friend made "Przyjaciel" on the phone reads what the computer '
      'writes for "Tylko przyjaciele" after', () async {
    final _World w = _World();
    final LedgerNode phone = await w.make(a1, <String>[b]);
    final LedgerNode bob = await w.make(b, <String>[a1, a2]);
    await _settle();
    final LedgerNode computer = await w.device(a2, phone, <String>[b]);
    await w.meet();
    expect(computer.levelOf(b), FriendLevel.friend);

    await phone.setLevel(b, FriendLevel.close);
    await w.meet();
    expect(computer.levelOf(b), FriendLevel.close);
    await _post(computer, Audience.close, 'Z komputera dla przyjaciół');
    await w.meet();
    expect(_texts(bob, phone.account), contains('Z komputera dla przyjaciół'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('both devices change the same friend\'s level while apart, with '
      'clocks minutes apart: both end with the same one; a change made '
      'after seeing the other wins whatever the clocks say', () async {
    final _World w = _World();
    // The phone's clock runs five minutes ahead of the computer's.
    final LedgerNode phone = await w.make(a1, <String>[b], skewMs: 300000);
    final LedgerNode bob = await w.make(b, <String>[a1, a2]);
    await _settle();
    final LedgerNode computer = await w.device(a2, phone, <String>[b]);
    await phone.setLevel(b, FriendLevel.close);
    await w.meet();
    expect(computer.levelOf(b), FriendLevel.close);

    // Apart: the computer is cut off while both change Bob's level.
    w.nodes.remove(a2);
    await computer.setLevel(b, FriendLevel.weak);
    await phone.setLevel(b, FriendLevel.friend);
    w.nodes[a2] = computer.transport as _Linked;
    await w.meet();
    expect(computer.levelOf(b), phone.levelOf(b), reason: 'one level');
    // The phone's change carries the later time (its clock is ahead).
    expect(phone.levelOf(b), FriendLevel.friend);

    // Now the computer, whose clock is behind every time it has seen,
    // changes the level again: its change came last and wins.
    await computer.setLevel(b, FriendLevel.weak);
    await w.meet();
    expect(phone.levelOf(b), FriendLevel.weak);
    expect(computer.levelOf(b), FriendLevel.weak);
    await _post(phone, Audience.mid, 'Dla znajomych i przyjaciół');
    await w.meet();
    expect(
      _texts(bob, phone.account),
      isNot(contains('Dla znajomych i przyjaciół')),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a device away for weeks comes back with an old level: it takes the '
      'new one and does not bring the old one back', () async {
    final _World w = _World();
    final LedgerNode phone = await w.make(a1, <String>[b, c]);
    final LedgerNode bob = await w.make(b, <String>[a1, a2]);
    await _settle();
    LedgerNode computer = await w.device(a2, phone, <String>[b, c]);
    await phone.setLevel(b, FriendLevel.close);
    await phone.setLevel(c, FriendLevel.weak);
    await w.meet();
    expect(computer.levelOf(b), FriendLevel.close);

    // The computer is switched off; meanwhile Bob goes down, Cel up.
    await w.off(a2);
    await phone.setLevel(b, FriendLevel.weak);
    await phone.setLevel(c, FriendLevel.close);
    await _settle();
    // Back, from what it saved before.
    computer = await w.make(a2, <String>[b, c]);
    expect(computer.levelOf(b), FriendLevel.close, reason: 'its old level');
    await w.meet();
    expect(computer.levelOf(b), FriendLevel.weak);
    expect(computer.levelOf(c), FriendLevel.close);
    expect(phone.levelOf(b), FriendLevel.weak, reason: 'never the old one');
    expect(phone.levelOf(c), FriendLevel.close);
    await _post(computer, Audience.close, 'Po powrocie, dla przyjaciół');
    await w.meet();
    expect(
      _texts(bob, phone.account),
      isNot(contains('Po powrocie, dla przyjaciół')),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a third device linked later takes the levels, and what it writes '
      'for a level a friend lost is not theirs to read', () async {
    final _World w = _World();
    final LedgerNode phone = await w.make(a1, <String>[b]);
    final LedgerNode bob = await w.make(b, <String>[a1, a2, a3]);
    await _settle();
    final LedgerNode computer = await w.device(a2, phone, <String>[b]);
    await phone.setLevel(b, FriendLevel.close);
    await w.meet();
    await computer.setLevel(b, FriendLevel.weak);
    await w.meet();

    final LedgerNode tablet = await w.device(a3, phone, <String>[b]);
    await w.meet();
    expect(tablet.levelOf(b), FriendLevel.weak);
    await _post(tablet, Audience.mid, 'Z tabletu dla znajomych');
    await w.meet();
    expect(
      _texts(bob, phone.account),
      isNot(contains('Z tabletu dla znajomych')),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('levels saved before they carried a time: two devices that disagree '
      'settle on the lower one', () async {
    final _World w = _World();
    final MemoryLedgerDisk phoneDisk = MemoryLedgerDisk();
    final MemoryLedgerDisk computerDisk = MemoryLedgerDisk();
    final first = await LedgerIdentity.loadOrCreate(phoneDisk);
    await LedgerIdentity.adoptAccount(computerDisk, first.accountKey!.seed);
    Uint8List old(Map<String, String> levels) =>
        Uint8List.fromList(utf8.encode(jsonEncode(levels)));
    await phoneDisk.write('ledger/levels', old(<String, String>{b: 'weak'}));
    await computerDisk.write(
      'ledger/levels',
      old(<String, String>{b: 'close'}),
    );
    final LedgerNode phone = await w.make(a1, <String>[b], disk: phoneDisk);
    final LedgerNode computer = await w.make(a2, <String>[
      b,
    ], disk: computerDisk);
    await computer.rememberDeviceAddresses(<String>[a1]);
    await w.meet();
    expect(phone.levelOf(b), FriendLevel.weak);
    expect(computer.levelOf(b), FriendLevel.weak);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a copy\'s levels come back, but never over a later change', () async {
    final _World w = _World();
    final LedgerNode ada = await w.make(a1, <String>[b, c]);
    await ada.setLevel(b, FriendLevel.close);
    await ada.setLevel(c, FriendLevel.close);
    final Map<String, Object> copy = ada.levelsForCopy(<String>[b, c]);
    expect(copy[LedgerNode.levelTimesKey], isA<Map<String, int>>());

    // A fresh device takes the copy as it is.
    final LedgerNode fresh = await w.make(_a('200::f'), <String>[b, c]);
    await fresh.takeLevels(jsonDecode(jsonEncode(copy)));
    expect(fresh.levelOf(b), FriendLevel.close);
    expect(fresh.levelOf(c), FriendLevel.close);

    // Bob went down after the copy was made: the copy leaves him there.
    await ada.setLevel(b, FriendLevel.weak);
    await ada.takeLevels(jsonDecode(jsonEncode(copy)));
    expect(ada.levelOf(b), FriendLevel.weak);
    expect(ada.levelOf(c), FriendLevel.close);

    // A copy made by Zen 1.16.5 (no times) fills only what is not set.
    await fresh.takeLevels(<String, String>{b: 'weak', c: 'friend'});
    expect(fresh.levelOf(b), FriendLevel.close);
    expect(fresh.levelOf(c), FriendLevel.close);
    final LedgerNode other = await w.make(_a('200::e'), <String>[b, c]);
    await other.takeLevels(<String, String>{b: 'weak', c: 'friend'});
    expect(other.levelOf(b), FriendLevel.weak);
    expect(other.levelOf(c), FriendLevel.friend);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
