import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/ledger_replicator.dart';
import 'package:zen/src/core/ledger/space_policy.dart';

import 'support/ledger_sim.dart';

String _feed(SimNode n) => accountSpace('feed', n.account);

Future<void> _post(SimNode n, int count) async {
  for (int i = 0; i < count; i++) {
    await n.author!.append(_feed(n), 'post', <String, dynamic>{'n': i});
  }
}

String _someDevice() => b64(randomBytes(32));

Future<DeviceRevocation> _revocation(
  LedgerKeyPair account, {
  String? device,
  Map<String, int> cutoffs = const <String, int>{},
  int issued = 1,
}) => DeviceRevocation.issue(
  account: account,
  device: device ?? _someDevice(),
  cutoffs: cutoffs,
  issued: issued,
);

Future<void> _sendRevocations(
  SimNode to,
  String from,
  List<Map<String, dynamic>> items,
) async {
  for (int i = 0; i < items.length; i += 64) {
    await to.replicator.handle(from, <String, dynamic>{
      'type': LedgerMessages.revoke,
      'items': items.sublist(i, min(i + 64, items.length)),
    });
  }
}

void main() {
  test('revocations of accounts nobody here knows are refused, never saved '
      'and never passed on', () async {
    final SimNet net = SimNet();
    final SimNode ada = net.add('ada');
    final SimNode bob = net.add('bob');
    final SimNode cel = net.add('cel');
    net
      ..link('ada', 'bob')
      ..link('bob', 'cel');
    await ada.becomeAuthor();
    bob.replicator.subscribe(_feed(ada));
    cel.replicator.subscribe(_feed(ada));
    await _post(ada, 1);
    await net.pump();
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerArchive archive = LedgerArchive(disk: disk);
    await archive.open(bob.store, bob.blobs);
    await archive.flush();
    final int indexBefore = disk.files[LedgerArchive.indexKey]!.length;

    // A hostile friend (a changed app) sends revocations, each of an
    // account it just made up.
    final List<Map<String, dynamic>> junk = <Map<String, dynamic>>[
      for (int i = 0; i < 130; i++)
        (await _revocation(await LedgerKeyPair.generate())).toJson(),
    ];
    net.sent.clear();
    await _sendRevocations(bob, 'ada', junk);
    await net.pump();
    await archive.flush();

    expect(bob.store.directory.revocationCount, 0);
    expect(disk.files[LedgerArchive.indexKey]!.length, indexBefore);
    expect(
      jsonDecode(utf8.decode(disk.files[LedgerArchive.revocationsKey]!)),
      isEmpty,
    );
    expect(net.sent[LedgerMessages.revoke], isNull, reason: 'not passed on');
    await archive.close();
  });

  test('an account cannot fill a phone with its own revocations', () async {
    final SimNet net = SimNet();
    final SimNode ada = net.add('ada');
    final SimNode bob = net.add('bob');
    net.link('ada', 'bob');
    await ada.becomeAuthor();
    bob.replicator.subscribe(_feed(ada));
    await _post(ada, 1);
    await net.pump();

    final List<Map<String, dynamic>> many = <Map<String, dynamic>>[
      for (int i = 0; i < 20; i++)
        (await _revocation(ada.accountSetup!.accountKey, issued: i)).toJson(),
    ];
    await _sendRevocations(bob, 'ada', many);
    // One device certified here, and a few more.
    expect(
      bob.store.directory.revocationCount,
      1 + AccountDirectory.spareRevocationsPerAccount,
    );
  });

  test('the revocations are bounded in all, and the oldest of an account '
      'that does not matter here make room for a friend\'s', () async {
    final AccountDirectory dir = AccountDirectory();
    final List<LedgerKeyPair> accounts = <LedgerKeyPair>[
      for (int i = 0; i < 2; i++) await LedgerKeyPair.generate(),
    ];
    final LedgerKeyPair friend = accounts.first;
    dir.isCoreAccount = (String account) => account == friend.id;
    // Fill it up with others (the limits are checked before signatures, so
    // trusted ones fill it the quick way).
    final DeviceRevocation sample = await _revocation(accounts.last);
    int filled = 0;
    while (filled < AccountDirectory.maxRevocations) {
      final DeviceRevocation r = DeviceRevocation(
        account: b64(randomBytes(32)),
        device: sample.device,
        cutoffs: const <String, int>{},
        issued: filled,
        signature: '${sample.signature}$filled',
      );
      expect(dir.trustRevocation(r), isTrue);
      filled++;
    }
    expect(dir.revocationCount, AccountDirectory.maxRevocations);
    expect(await dir.addRevocation(await _revocation(accounts.last)), isFalse);
    final DeviceRevocation friends = await _revocation(friend);
    expect(await dir.addRevocation(friends), isTrue);
    expect(dir.isRevoked(friend.id, friends.device), isTrue);
    expect(dir.revocationCount, AccountDirectory.maxRevocations);
  });

  test('more than 64 revocations reach a friend who was offline, in '
      'messages a signal can carry, and only once', () async {
    final SimNet net = SimNet();
    final SimNode hub = net.add('hub');
    final SimNode zoe = net.add('zoe');
    net.link('hub', 'zoe');
    final List<SimNode> authors = <SimNode>[
      for (int i = 0; i < 25; i++) net.add('a$i'),
    ];
    for (final SimNode a in authors) {
      net.link(a.name, 'hub');
      await a.becomeAuthor();
      hub.replicator.subscribe(_feed(a));
      zoe.replicator.subscribe(_feed(a));
      await _post(a, 1);
    }
    await net.pump();
    final Set<String> friends = <String>{
      for (final SimNode a in authors) a.account,
    };
    zoe.knowsAccount = friends.contains;
    for (final SimNode a in authors) {
      expect(zoe.store.entries(_feed(a)), hasLength(1));
      // Their phones stay out of the syncs below.
      a.online = false;
    }

    // While Zoe is away, the hub learns of 100 cut-off devices.
    zoe.online = false;
    for (final SimNode a in authors) {
      for (int i = 0; i < 4; i++) {
        expect(
          await hub.store.applyRevocation(
            await _revocation(a.accountSetup!.accountKey, issued: i),
          ),
          greaterThanOrEqualTo(0),
        );
      }
    }
    expect(hub.store.directory.revocationCount, 100);

    zoe.online = true;
    net
      ..sent.clear()
      ..largest.clear();
    await net.syncRounds(1);
    expect(zoe.store.directory.revocationCount, 100);
    expect(
      net.largest[LedgerMessages.revoke],
      lessThan(2 * 1024 * 1024),
      reason: 'a signal carries at most 2 MB',
    );

    // The next syncs do not carry them again.
    net.sent.clear();
    await net.syncRounds(1);
    expect(net.sent[LedgerMessages.revoke], isNull);
  });

  test('a revocation comes with the certificate of the device it cuts '
      'off, before that device\'s entries are taken', () async {
    final SimNet net = SimNet();
    final SimNode ada = net.add('ada');
    final SimNode hub = net.add('hub');
    final SimNode bob = net.add('bob');
    net
      ..link('ada', 'hub')
      ..link('hub', 'bob');
    await ada.becomeAuthor();
    hub.replicator.subscribe(_feed(ada));
    await _post(ada, 4);
    await net.pump();
    expect(hub.store.entries(_feed(ada)), hasLength(4));
    ada.online = false;
    // Ada's phone was stolen; the hub knows it, Bob (who knows nobody yet,
    // so takes no revocation of Ada's in a sync) does not.
    final DeviceRevocation cut = await _revocation(
      ada.accountSetup!.accountKey,
      device: ada.author!.deviceKey.id,
      cutoffs: <String, int>{ada.author!.writer: 2},
    );
    await hub.store.applyRevocation(cut);

    bob.replicator.subscribe(_feed(ada));
    await net.syncRounds(1);
    expect(bob.store.directory.isRevoked(ada.account, cut.device), isTrue);
    expect(bob.store.entries(_feed(ada)), hasLength(2));
  });
}
