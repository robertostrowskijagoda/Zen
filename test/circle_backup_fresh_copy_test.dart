import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/account/circle_backup_holder.dart';
import 'package:zen/src/features/account/circle_backup_service.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// A new phone still looking for its copy makes one of its own only on the
/// person's word; a holder then keeps the much bigger copy before it for a
/// while, and the search takes that one back. A holder that keeps
/// refusing new copies as older is shown to the owner.
void main() {
  late int now;

  setUp(() {
    _Linked.nodes.clear();
    now = DateTime.utc(2026, 11, 1).millisecondsSinceEpoch;
  });

  test('on the person\'s word the new phone makes its own copy; the friend '
      'keeps the whole one before it, and the search still takes it '
      'back', () async {
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final _Linked tHolder = _Linked('200::b');
    final _Linked tNew = _Linked('200::c');
    await tHolder.start();
    await tNew.start();
    final CircleBackupService holder = CircleBackupService(
      transport: tHolder,
      disk: MemoryLedgerDisk(),
      data: _MemoryData(const CircleBackupContent()),
      identity: () => null,
      holders: () => const <String>[],
      isInCircle: (String a) => a == me.account,
      restoreCandidates: () => const <String>[],
      clock: () => now,
    );
    await holder.start();
    final CircleBackupBuild full = await buildCircleBackup(
      content: _full(),
      account: me.account,
      selfKey: me.selfKey!,
      deviceKey: me.deviceKey,
      certificate: me.certificate,
      at: now - 3600 * 1000,
    );
    await _keep(holder, full);
    _Linked.nodes.remove(tHolder.address);

    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerIdentity recovered = await LedgerIdentity.adoptAccount(
      disk,
      me.accountKey!.seed,
    );
    await CircleBackupService.markRestore(
      disk,
      helpers: <String>[tHolder.address],
      at: now,
    );
    final _MemoryData restored = _MemoryData(_empty());
    final CircleBackupService fresh = CircleBackupService(
      transport: tNew,
      disk: disk,
      data: restored,
      identity: () => CircleBackupIdentity(
        account: recovered.account,
        selfKey: recovered.selfKey!,
        deviceKey: recovered.deviceKey,
        certificate: recovered.certificate,
      ),
      holders: () => const <String>[],
      isInCircle: (_) => false,
      restoreCandidates: () => <String>[tHolder.address],
      friendHolders: () => <String>[tHolder.address],
      clock: () => now,
    );
    await fresh.start();
    await _settle(<CircleBackupService>[fresh, holder]);
    // "Zrób kopię teraz" makes nothing while the copy is looked for.
    await fresh.refresh(force: true);
    expect(_sent(tNew, CircleBackupMessages.offer), 0);

    // The friend is back; the person says to make a copy from here.
    _Linked.nodes[tHolder.address] = tHolder;
    await fresh.allowFreshCopy();
    await _settle(<CircleBackupService>[fresh, holder]);
    expect(fresh.restore.value.freshCopy, isTrue);
    final CircleBackupManifest mine = holder.holder.manifestOf(me.account)!;
    expect(mine.id, isNot(full.manifest.id));
    expect(mine.totalBytes * 2, lessThan(full.manifest.totalBytes));
    expect(holder.holder.previousOf(me.account)!.id, full.manifest.id);
    expect(restored.restoredContent, isNull, reason: 'its own copy is no use');

    // The next look takes the whole copy back, from the one kept before.
    now += const Duration(minutes: 15).inMilliseconds;
    await fresh.tick();
    await _settle(<CircleBackupService>[fresh, holder]);
    expect(fresh.restore.value.phase, CircleBackupRestorePhase.done);
    expect(
      restored.restoredContent!.sections[CircleBackupSections.passwords],
      <String, dynamic>{'bank': 'tajne'},
    );
    expect(fresh.restoring, isFalse);

    // The one before goes after its time, with its chunks.
    now += kCircleBackupPreviousKept.inMilliseconds;
    await holder.tick();
    expect(holder.holder.previousOf(me.account), isNull);
    for (final CircleBackupService s in <CircleBackupService>[fresh, holder]) {
      await s.stop();
    }
  });

  test('a holder keeps the one before only when the new copy is much '
      'smaller, and it goes first when room is short', () async {
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final CircleBackupBuild full = await buildCircleBackup(
      content: _full(),
      account: me.account,
      selfKey: me.selfKey!,
      deviceKey: me.deviceKey,
      certificate: me.certificate,
      at: now - 2000,
    );
    final CircleBackupBuild same = await buildCircleBackup(
      content: _full(),
      account: me.account,
      selfKey: me.selfKey!,
      deviceKey: me.deviceKey,
      certificate: me.certificate,
      at: now - 1000,
    );
    final CircleBackupBuild small = await buildCircleBackup(
      content: _empty(),
      account: me.account,
      selfKey: me.selfKey!,
      deviceKey: me.deviceKey,
      certificate: me.certificate,
      at: now,
    );
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    CircleBackupHolder holderWith(int total) => CircleBackupHolder(
      disk: disk,
      isInCircle: (String a) => a == me.account,
      clock: () => now,
      totalBytes: total,
    );
    Future<void> keep(CircleBackupHolder h, CircleBackupBuild b) async {
      expect(await h.offer(b.manifest), CircleBackupOfferResult.accepted);
      for (final MapEntry<String, Uint8List> e in b.chunks.entries) {
        await h.putChunk(me.account, e.key, e.value);
      }
    }

    final CircleBackupHolder h = holderWith(kCircleBackupHolderTotalBytes);
    await keep(h, full);
    await keep(h, same);
    expect(h.previousOf(me.account), isNull, reason: 'not much smaller');
    await keep(h, small);
    expect(h.previousOf(me.account)!.id, same.manifest.id);
    // Its chunks are still there, and survive a restart.
    final CircleBackupHolder again = holderWith(kCircleBackupHolderTotalBytes);
    await again.load();
    expect(again.previousOf(me.account)!.id, same.manifest.id);
    for (final String id in same.chunks.keys) {
      expect(await again.chunk(me.account, id), same.chunks[id]);
    }

    // Room for the copies but not for the one before as well.
    final MemoryLedgerDisk tight = MemoryLedgerDisk();
    final CircleBackupHolder t = CircleBackupHolder(
      disk: tight,
      isInCircle: (String a) => a == me.account,
      clock: () => now,
      totalBytes: full.manifest.totalBytes + small.manifest.totalBytes - 1,
    );
    expect(await t.offer(full.manifest), CircleBackupOfferResult.accepted);
    for (final MapEntry<String, Uint8List> e in full.chunks.entries) {
      await t.putChunk(me.account, e.key, e.value);
    }
    expect(await t.offer(small.manifest), CircleBackupOfferResult.accepted);
    for (final MapEntry<String, Uint8List> e in small.chunks.entries) {
      await t.putChunk(me.account, e.key, e.value);
    }
    expect(t.manifestOf(me.account)!.id, small.manifest.id);
    expect(t.previousOf(me.account), isNull);
  });

  test('a holder that keeps a copy dated ahead refuses the owner\'s copies, '
      'and the owner is told', () async {
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final _Linked tOwner = _Linked('200::a');
    final _Linked tHolder = _Linked('200::b');
    await tOwner.start();
    await tHolder.start();
    // The holder's own clock is ahead too: the copy is not ahead for it.
    final int holderNow = DateTime.utc(2036, 1, 2).millisecondsSinceEpoch;
    final CircleBackupService holder = CircleBackupService(
      transport: tHolder,
      disk: MemoryLedgerDisk(),
      data: _MemoryData(const CircleBackupContent()),
      identity: () => null,
      holders: () => const <String>[],
      isInCircle: (String a) => a == me.account,
      restoreCandidates: () => const <String>[],
      clock: () => holderNow,
    );
    await holder.start();
    await _keep(
      holder,
      await buildCircleBackup(
        content: _empty(),
        account: me.account,
        selfKey: me.selfKey!,
        deviceKey: me.deviceKey,
        certificate: me.certificate,
        at: DateTime.utc(2036).millisecondsSinceEpoch,
      ),
    );
    final CircleBackupService owner = CircleBackupService(
      transport: tOwner,
      disk: MemoryLedgerDisk(),
      data: _MemoryData(_full()),
      identity: () => CircleBackupIdentity(
        account: me.account,
        selfKey: me.selfKey!,
        deviceKey: me.deviceKey,
        certificate: me.certificate,
      ),
      holders: () => <String>[tHolder.address],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
      clock: () => now,
    );
    await owner.start();
    await _settle(<CircleBackupService>[owner, holder]);
    expect(owner.status.value.lastAt, isNull);
    expect(owner.status.value.blocked, 1);
    for (final CircleBackupService s in <CircleBackupService>[owner, holder]) {
      await s.stop();
    }
  });

  test('a holder that refuses as older for days, saying no date, is shown '
      'after a while', () async {
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final _Linked tOwner = _Linked('200::a');
    final _Linked tHolder = _Linked('200::b');
    await tOwner.start();
    await tHolder.start();
    final CircleBackupService owner = CircleBackupService(
      transport: tOwner,
      disk: MemoryLedgerDisk(),
      data: _MemoryData(_full()),
      identity: () => CircleBackupIdentity(
        account: me.account,
        selfKey: me.selfKey!,
        deviceKey: me.deviceKey,
        certificate: me.certificate,
      ),
      holders: () => <String>[tHolder.address],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
      clock: () => now,
    );
    await owner.start();
    await _settle(<CircleBackupService>[owner]);
    // An older holder answers every offer "stale" without a date.
    Future<void> refuse() async {
      await tHolder.send(
        remoteAddress: tOwner.address,
        payload: <String, dynamic>{
          'type': CircleBackupMessages.no,
          'a': me.account,
          'why': 'stale',
        },
      );
      await _settle(<CircleBackupService>[owner]);
    }

    await refuse();
    expect(owner.status.value.blocked, 0, reason: 'another device\'s copy');
    now += CircleBackupService.blockedAfter.inMilliseconds;
    await refuse();
    expect(owner.status.value.blocked, 1);
    await owner.stop();
  });
}

final class _MemoryData implements CircleBackupData {
  _MemoryData(this.content);

  final CircleBackupContent content;
  CircleBackupContent? restoredContent;

  @override
  Future<CircleBackupContent> collect({required bool chats}) async => content;

  @override
  Future<void> restore(
    CircleBackupContent content,
    void Function(int done, int total) progress,
  ) async {
    restoredContent = content;
    progress(1, 1);
  }
}

final class _Linked extends MemorySignalTransport {
  _Linked(String address) : address = PeerShareCodec.normalizeAddress(address) {
    nodes[this.address] = this;
  }

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
      final Map<String, dynamic> wire =
          jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: wire),
      );
    }
  }
}

Future<void> _settle(List<CircleBackupService> services) async {
  for (int i = 0; i < 200; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    for (final CircleBackupService s in services) {
      await s.idle;
    }
  }
}

int _sent(_Linked t, String type) =>
    t.sentSignals.where((s) => s.payload['type'] == type).length;

CircleBackupContent _full() => CircleBackupContent(
  sections: <String, Object?>{
    CircleBackupSections.profile: <String, dynamic>{'displayName': 'Ola'},
    CircleBackupSections.passwords: <String, dynamic>{'bank': 'tajne'},
    CircleBackupSections.notes: <String, dynamic>{'n1': 'notatka'},
  },
  chats: <String, List<Map<String, dynamic>>>{
    'rozmowa': <Map<String, dynamic>>[
      for (int i = 0; i < 40; i++)
        <String, dynamic>{
          'id': 'm$i',
          's': 'ada',
          't': 'Cześć, co słychać? Wiadomość numer $i ${'x' * 60}',
          'at': DateTime.utc(2026, 1, 1, i).millisecondsSinceEpoch,
          'd': 'incoming',
          'ty': 'text',
          'ds': 'none',
        },
    ],
  },
);

CircleBackupContent _empty() => const CircleBackupContent(
  sections: <String, Object?>{
    CircleBackupSections.profile: <String, dynamic>{'displayName': 'Ola'},
  },
);

Future<void> _keep(CircleBackupService holder, CircleBackupBuild b) async {
  await holder.holder.offer(b.manifest);
  for (final MapEntry<String, Uint8List> e in b.chunks.entries) {
    await holder.holder.putChunk(b.manifest.account, e.key, e.value);
  }
}
