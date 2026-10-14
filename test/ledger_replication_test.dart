import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';

import 'support/ledger_sim.dart';

String _feed(SimNode n) => accountSpace('feed', n.account);

Future<void> _post(SimNode n, int count, {String prefix = 'post'}) async {
  for (int i = 0; i < count; i++) {
    await n.author!.append(_feed(n), 'post', <String, dynamic>{
      'text': '$prefix $i',
    });
  }
}

void _subscribeAll(SimNet net, Iterable<SimNode> authors) {
  for (final SimNode node in net.nodes.values) {
    for (final SimNode a in authors) {
      node.replicator.subscribe(_feed(a));
    }
  }
}

void main() {
  test('two devices catch up with each other both ways', () async {
    final SimNet net = SimNet();
    final SimNode ada = net.add('ada');
    final SimNode bob = net.add('bob');
    net.link('ada', 'bob');
    await ada.becomeAuthor();
    await bob.becomeAuthor();
    _subscribeAll(net, <SimNode>[ada, bob]);

    await _post(ada, 4);
    bob.online = false;
    await net.pump();
    await _post(bob, 3);
    bob.online = true;

    await net.syncRounds(1);

    for (final SimNode n in <SimNode>[ada, bob]) {
      expect(n.store.entries(_feed(ada)), hasLength(4), reason: n.name);
      expect(n.store.entries(_feed(bob)), hasLength(3), reason: n.name);
    }
  });

  test('news travels along a chain of friends', () async {
    final SimNet net = SimNet();
    final List<SimNode> chain = <SimNode>[
      for (final String name in <String>['a', 'b', 'c', 'd', 'e', 'f'])
        net.add(name),
    ];
    for (int i = 0; i + 1 < chain.length; i++) {
      net.link(chain[i].name, chain[i + 1].name);
    }
    await chain.first.becomeAuthor();
    _subscribeAll(net, <SimNode>[chain.first]);

    await _post(chain.first, 10);
    await net.pump();

    // Pushed hop by hop as each device learns of it; no sync round needed.
    expect(chain.last.store.entries(_feed(chain.first)), hasLength(10));
  });

  test(
    'a lossy network with devices dropping in and out still converges',
    () async {
      final SimNet net = SimNet(seed: 42, dropRate: 0.25);
      final List<SimNode> nodes = <SimNode>[
        for (int i = 0; i < 8; i++) net.add('n$i'),
      ];
      // A ring plus a few chords: everyone reachable, nobody linked to all.
      for (int i = 0; i < nodes.length; i++) {
        net.link(nodes[i].name, nodes[(i + 1) % nodes.length].name);
      }
      net
        ..link('n0', 'n4')
        ..link('n2', 'n6');
      final List<SimNode> authors = <SimNode>[nodes[0], nodes[3], nodes[5]];
      for (final SimNode a in authors) {
        await a.becomeAuthor();
      }
      _subscribeAll(net, authors);

      for (int round = 0; round < 5; round++) {
        net.randomlyToggle(0.3);
        for (final SimNode a in authors) {
          await _post(a, 3, prefix: 'r$round');
        }
        await net.syncRounds(1);
      }

      net
        ..allOnline()
        ..dropRate = 0;
      await net.syncRounds(2);

      for (final SimNode n in nodes) {
        for (final SimNode a in authors) {
          expect(
            n.store.heads(_feed(a)),
            a.store.heads(_feed(a)),
            reason: '${n.name} ma dziennik ${a.name}',
          );
          expect(n.store.entries(_feed(a)), hasLength(15));
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('nobody can push entries of a space we did not ask for', () async {
    final SimNet net = SimNet();
    final SimNode eve = net.add('eve');
    final SimNode ada = net.add('ada');
    net.link('eve', 'ada');
    await eve.becomeAuthor();
    // Ada follows nothing of Eve's.
    await _post(eve, 3);
    await net.pump();
    eve.replicator.syncWith('ada', extra: <String>[_feed(eve)]);
    await net.pump();
    // Straight push of entries, unasked.
    await ada.replicator.handle('eve', <String, dynamic>{
      'type': 'lg_entries',
      'entries': <Map<String, dynamic>>[
        for (final LogEntry e in eve.store.entries(_feed(eve))) e.toJson(),
      ],
    });
    expect(ada.store.holdsSpace(_feed(eve)), isFalse);
  });

  test('the app can refuse pushes from particular peers', () async {
    final SimNet net = SimNet();
    final SimNode ada = net.add('ada');
    final SimNode stranger = net.add('stranger');
    final SimNode friend = net.add('friend');
    net
      ..link('ada', 'stranger')
      ..link('ada', 'friend');
    await stranger.becomeAuthor();
    await friend.becomeAuthor();
    ada.replicator
      ..subscribe(_feed(stranger))
      ..subscribe(_feed(friend));
    ada.acceptsFrom = (String peer, String space) => peer == 'friend';
    await _post(stranger, 2);
    await _post(friend, 2);
    await net.pump();
    expect(ada.store.entries(_feed(friend)), hasLength(2));
    expect(ada.store.holdsSpace(_feed(stranger)), isFalse);
  });

  test('a cut-off device is cut off everywhere', () async {
    final SimNet net = SimNet();
    final List<SimNode> nodes = <SimNode>[
      for (final String name in <String>['owner', 'x', 'y', 'z']) net.add(name),
    ];
    net
      ..link('owner', 'x')
      ..link('x', 'y')
      ..link('y', 'z');
    await nodes.first.becomeAuthor();
    _subscribeAll(net, <SimNode>[nodes.first]);
    await _post(nodes.first, 4);
    await net.pump();
    expect(nodes.last.store.entries(_feed(nodes.first)), hasLength(4));

    final SimNode owner = nodes.first;
    final DeviceRevocation revocation = await DeviceRevocation.issue(
      account: owner.accountSetup!.accountKey,
      device: owner.author!.deviceKey.id,
      cutoffs: <String, int>{owner.author!.writer: 2},
      issued: 5,
    );
    await owner.replicator.publishRevocation(revocation);
    await net.pump();

    for (final SimNode n in nodes) {
      expect(n.store.entries(_feed(owner)), hasLength(2), reason: n.name);
    }
  });

  group('files', () {
    test('a file comes in pieces from several devices', () async {
      final SimNet net = SimNet();
      final SimNode a = net.add('a');
      final SimNode b = net.add('b');
      final SimNode c = net.add('c');
      net
        ..link('c', 'a')
        ..link('c', 'b');
      final Uint8List video = Uint8List.fromList(simBytes(700 * 1024));
      final String id = await a.blobs.put(video, mime: 'video/mp4');
      await b.blobs.put(video, mime: 'video/mp4');

      String? completed;
      c.replicator.onBlobComplete = (String done) => completed = done;
      c.replicator.fetchBlob(id, <String>['a', 'b']);
      await net.pump();

      expect(completed, id);
      expect(await c.blobs.read(id), video);
    });

    test('a device sending a wrong piece cannot spoil the file', () async {
      final SimNet net = SimNet();
      final SimNode good = net.add('good');
      final SimNode liar = net.add('liar');
      final SimNode me = net.add('me');
      net
        ..link('me', 'good')
        ..link('me', 'liar');
      final Uint8List photo = Uint8List.fromList(simBytes(300 * 1024));
      final String id = await good.blobs.put(photo);
      // The liar has the manifest but garbage behind each hash.
      await liar.blobs.put(Uint8List.fromList(simBytes(300 * 1024, seed: 99)));

      me.replicator.fetchBlob(id, <String>['liar', 'good']);
      await net.pump();
      await me.replicator.handle('liar', <String, dynamic>{
        'type': 'lg_blob_chunk',
        'h': good.blobs.manifest(id)!.chunks.first,
        'd': 'AAAA',
      });
      await net.syncRounds(2);

      expect(await me.blobs.read(id), photo);
    });

    test('pieces trickle in over a lossy network', () async {
      final SimNet net = SimNet(seed: 3, dropRate: 0.3);
      final SimNode a = net.add('a');
      final SimNode b = net.add('b');
      net.link('a', 'b');
      final Uint8List file = Uint8List.fromList(simBytes(1024 * 1024));
      final String id = await a.blobs.put(file);
      b.replicator.fetchBlob(id, <String>['a']);
      await net.pump();
      for (int i = 0; i < 20 && !b.blobs.isComplete(id); i++) {
        await net.syncRounds(1);
      }
      expect(await b.blobs.read(id), file);
    });
  });

  test('entries survive the wire unchanged (ids match)', () async {
    final SimNet net = SimNet();
    final SimNode a = net.add('a');
    final SimNode b = net.add('b');
    net.link('a', 'b');
    await a.becomeAuthor();
    _subscribeAll(net, <SimNode>[a]);
    final LogEntry sent = await a.author!.append(
      _feed(a),
      'post',
      <String, dynamic>{
        'text': 'Zażółć gęślą jaźń 🙂',
        'tags': <String>['a', 'b'],
        'nested': <String, dynamic>{'n': 1, 'm': null},
      },
    );
    await net.pump();
    expect(b.store.entryById(_feed(a), sent.id), isNotNull);
    expect(b.store.headOf(_feed(a), a.author!.writer), 1);
    expect((await b.store.ingest(sent)).status, IngestStatus.duplicate);
  });
}
