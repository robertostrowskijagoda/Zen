import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/account/circle_backup_service.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// A device that is taking the copy with friends back after a recovery
/// never replaces that copy with its own on its own: not when the copy was
/// made by a newer Zen, not when nothing was found for a month. A copy
/// dated ahead (a device whose clock ran ahead, perhaps cut off since)
/// does not keep a holder from taking the real ones.
void main() {
  late int now;

  setUp(() {
    _Linked.nodes.clear();
    now = DateTime.utc(2026, 11, 1).millisecondsSinceEpoch;
  });

  CircleBackupService holderOf(
    _Linked t,
    LedgerIdentity owner, {
    Set<String> revoked = const <String>{},
    int Function()? clock,
  }) => CircleBackupService(
    transport: t,
    disk: MemoryLedgerDisk(),
    data: _MemoryData(const CircleBackupContent()),
    identity: () => null,
    holders: () => const <String>[],
    isInCircle: (String a) => a == owner.account,
    restoreCandidates: () => const <String>[],
    isRevoked: (String account, String device) => revoked.contains(device),
    clock: clock ?? () => now,
  );

  /// A new phone of [owner]'s account, looking for its copy since [since].
  Future<(CircleBackupService, _MemoryData)> recovering(
    LedgerIdentity owner,
    _Linked t,
    String helper, {
    required int since,
    Set<String> revoked = const <String>{},
  }) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerIdentity recovered = await LedgerIdentity.adoptAccount(
      disk,
      owner.accountKey!.seed,
    );
    await CircleBackupService.markRestore(
      disk,
      helpers: <String>[helper],
      at: since,
    );
    final _MemoryData data = _MemoryData(_empty());
    final CircleBackupService fresh = CircleBackupService(
      transport: t,
      disk: disk,
      data: data,
      identity: () => _idOf(recovered),
      holders: () => const <String>[],
      isInCircle: (_) => false,
      restoreCandidates: () => <String>[helper],
      // The friend is back among the friends (from the ledger's backup).
      friendHolders: () => <String>[helper],
      isRevoked: (String account, String device) => revoked.contains(device),
      clock: () => now,
    );
    return (fresh, data);
  }

  test('a copy made by a newer Zen keeps the search going: the friend keeps '
      'that copy and no copy of the new phone replaces it', () async {
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final _Linked tHolder = _Linked('200::b');
    final _Linked tNew = _Linked('200::c');
    await tHolder.start();
    await tNew.start();
    final CircleBackupService holder = holderOf(tHolder, me);
    await holder.start();

    // The lost phone ran a newer Zen: its copy (version 2) is at the friend.
    final CircleBackupBuild v1 = await _build(me, at: now - 3600 * 1000);
    final Map<String, dynamic> body = <String, dynamic>{
      for (final MapEntry<String, dynamic> e in v1.manifest.json.entries)
        if (e.key != 'sig') e.key: e.key == 'v' ? 2 : e.value,
    };
    final List<int> sig = await me.deviceKey.sign(
      utf8.encode(jsonEncode(body)),
    );
    final CircleBackupManifest v2 = CircleBackupManifest.parse(
      jsonDecode(jsonEncode(<String, dynamic>{...body, 'sig': b64(sig)})),
    )!;
    expect(await v2.verify(), isTrue);
    await _keep(
      holder,
      CircleBackupBuild(manifest: v2, chunks: v1.chunks, droppedMessages: 0),
    );

    final (CircleBackupService fresh, _MemoryData restored) = await recovering(
      me,
      tNew,
      tHolder.address,
      since: now,
    );
    await fresh.start();
    await _settle(<CircleBackupService>[fresh, holder]);
    expect(fresh.restore.value.phase, CircleBackupRestorePhase.newer);
    expect(fresh.restoring, isTrue, reason: 'still looked for');

    // Ticks later (15 minutes each in the app), and a day later.
    for (int i = 0; i < 3; i++) {
      now += const Duration(hours: 9).inMilliseconds;
      await fresh.tick();
      await _settle(<CircleBackupService>[fresh, holder]);
    }
    final CircleBackupManifest kept = holder.holder.manifestOf(me.account)!;
    expect(kept.id, v2.id, reason: 'the whole copy stays at the friend');
    expect(_offersFrom(tNew), isEmpty);
    expect(restored.restoredContent, isNull);
    expect(fresh.restoring, isTrue);
    for (final CircleBackupService s in <CircleBackupService>[fresh, holder]) {
      await s.stop();
    }
  });

  test('nothing found for a month: the search goes on once a day, nothing '
      'replaces the friend\'s copy, and the copy comes back when the friend '
      'does', () async {
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final _Linked tHolder = _Linked('200::b');
    final _Linked tNew = _Linked('200::c');
    await tHolder.start();
    await tNew.start();
    final CircleBackupService holder = holderOf(tHolder, me);
    await holder.start();
    final CircleBackupBuild full = await _build(
      me,
      at: now - const Duration(days: 40).inMilliseconds,
    );
    await _keep(holder, full);
    // The friend is away (abroad, the phone off) for more than a month.
    _Linked.nodes.remove(tHolder.address);

    final (CircleBackupService fresh, _MemoryData restored) = await recovering(
      me,
      tNew,
      tHolder.address,
      since: now - const Duration(days: 31).inMilliseconds,
    );
    await fresh.start();
    await _settle(<CircleBackupService>[fresh, holder]);
    expect(fresh.restoring, isTrue, reason: 'a month is no reason to stop');
    expect(fresh.restore.value.phase, CircleBackupRestorePhase.failed);
    // More ticks the same day: not asked again, and no copy of its own.
    final int fetches = _sent(tNew, CircleBackupMessages.fetch);
    for (int i = 0; i < 4; i++) {
      now += const Duration(minutes: 15).inMilliseconds;
      await fresh.tick();
    }
    await _settle(<CircleBackupService>[fresh, holder]);
    expect(_sent(tNew, CircleBackupMessages.fetch), fetches);
    expect(_offersFrom(tNew), isEmpty);

    // The friend is back; the next day's ask finds the copy.
    _Linked.nodes[tHolder.address] = tHolder;
    now += const Duration(days: 1).inMilliseconds;
    await fresh.tick();
    await _settle(<CircleBackupService>[fresh, holder]);
    expect(fresh.restore.value.phase, CircleBackupRestorePhase.done);
    expect(
      restored.restoredContent!.sections[CircleBackupSections.passwords],
      <String, dynamic>{'bank': 'tajne'},
    );
    expect(holder.holder.manifestOf(me.account)!.id, full.manifest.id);
    expect(fresh.restoring, isFalse);
    for (final CircleBackupService s in <CircleBackupService>[fresh, holder]) {
      await s.stop();
    }
  });

  test('a copy dated in the future is refused, and one kept from before '
      'stops counting: dated ahead, or signed by a device the account cut '
      'off', () async {
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final _Linked tOwner = _Linked('200::a');
    final _Linked tHolder = _Linked('200::b');
    final _Linked tNew = _Linked('200::c');
    for (final _Linked t in <_Linked>[tOwner, tHolder, tNew]) {
      await t.start();
    }
    final Set<String> revoked = <String>{};
    // The holder's clock is right; it was wrong once (see below).
    int holderNow = now;
    final CircleBackupService holder = holderOf(
      tHolder,
      me,
      revoked: revoked,
      clock: () => holderNow,
    );
    await holder.start();

    // A second device of the account (a stolen phone whose clock was set
    // forward, or a computer with a wrong clock) makes a copy dated 2036.
    final LedgerKeyPair otherKey = await LedgerKeyPair.generate();
    final DeviceCertificate otherCert = await DeviceCertificate.issue(
      account: me.accountKey!,
      device: otherKey,
      name: 'Telefon',
      issued: 1,
    );
    final CircleBackupBuild future = await buildCircleBackup(
      content: _empty(),
      account: me.account,
      selfKey: me.selfKey!,
      deviceKey: otherKey,
      certificate: otherCert,
      at: DateTime.utc(2036).millisecondsSinceEpoch,
    );
    // Offered now: refused.
    await tOwner.send(
      remoteAddress: tHolder.address,
      payload: <String, dynamic>{
        'type': CircleBackupMessages.offer,
        'm': future.manifest.json,
      },
    );
    await _settle(<CircleBackupService>[holder]);
    expect(holder.holder.manifestOf(me.account), isNull);
    expect(_refusals(tHolder), contains('future'));

    // Kept while the holder's own clock was ahead.
    holderNow = DateTime.utc(2036, 1, 2).millisecondsSinceEpoch;
    await _keep(holder, future);
    holderNow = now;
    expect(
      holder.holder.manifestOf(me.account)!.createdAt,
      future.manifest.createdAt,
    );

    // The real phone's full copy is taken over it all the same.
    final _MemoryData mine = _MemoryData(_full());
    final CircleBackupService owner = CircleBackupService(
      transport: tOwner,
      disk: MemoryLedgerDisk(),
      data: mine,
      identity: () => _idOf(me),
      holders: () => <String>[tHolder.address],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
      isRevoked: (String account, String device) => revoked.contains(device),
      clock: () => now,
    );
    await owner.start();
    await _settle(<CircleBackupService>[owner, holder]);
    expect(holder.holder.manifestOf(me.account)!.createdAt, now);
    expect(owner.status.value.lastAt, now);
    await owner.stop();

    // Again a copy of the other device (kept while the clock was ahead),
    // then the account cuts that device off: the holder drops it.
    holderNow = DateTime.utc(2036, 1, 2).millisecondsSinceEpoch;
    final CircleBackupBuild later = await buildCircleBackup(
      content: _empty(),
      account: me.account,
      selfKey: me.selfKey!,
      deviceKey: otherKey,
      certificate: otherCert,
      at: DateTime.utc(2036, 1, 1).millisecondsSinceEpoch,
    );
    await _keep(holder, later);
    holderNow = now;
    revoked.add(otherKey.id);
    await holder.tick();
    expect(holder.holder.manifestOf(me.account), isNull);
    for (final CircleBackupService s in <CircleBackupService>[holder]) {
      await s.stop();
    }
  });

  test('a future copy kept at the friend, from a device cut off since, no '
      'longer leaves a recovery without anything', () async {
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final _Linked tOwner = _Linked('200::a');
    final _Linked tHolder = _Linked('200::b');
    final _Linked tNew = _Linked('200::c');
    for (final _Linked t in <_Linked>[tOwner, tHolder, tNew]) {
      await t.start();
    }
    final Set<String> revoked = <String>{};
    int holderNow = DateTime.utc(2036, 1, 2).millisecondsSinceEpoch;
    final CircleBackupService holder = holderOf(
      tHolder,
      me,
      revoked: revoked,
      clock: () => holderNow,
    );
    await holder.start();
    final LedgerKeyPair otherKey = await LedgerKeyPair.generate();
    final DeviceCertificate otherCert = await DeviceCertificate.issue(
      account: me.accountKey!,
      device: otherKey,
      name: 'Telefon',
      issued: 1,
    );
    await _keep(
      holder,
      await buildCircleBackup(
        content: _empty(),
        account: me.account,
        selfKey: me.selfKey!,
        deviceKey: otherKey,
        certificate: otherCert,
        at: DateTime.utc(2036).millisecondsSinceEpoch,
      ),
    );
    holderNow = now;
    revoked.add(otherKey.id);

    final CircleBackupService owner = CircleBackupService(
      transport: tOwner,
      disk: MemoryLedgerDisk(),
      data: _MemoryData(_full()),
      identity: () => _idOf(me),
      holders: () => <String>[tHolder.address],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
      isRevoked: (String account, String device) => revoked.contains(device),
      clock: () => now,
    );
    await owner.start();
    await _settle(<CircleBackupService>[owner, holder]);
    expect(_refusals(tHolder), isNot(contains('stale')));
    expect(owner.status.value.lastAt, isNotNull);
    await owner.stop();

    // The phone is lost; the account comes back; the copy with it.
    final (CircleBackupService fresh, _MemoryData restored) = await recovering(
      me,
      tNew,
      tHolder.address,
      since: now,
      revoked: revoked,
    );
    await fresh.start();
    await _settle(<CircleBackupService>[fresh, holder]);
    expect(fresh.restore.value.phase, CircleBackupRestorePhase.done);
    expect(
      restored.restoredContent!.sections[CircleBackupSections.notes],
      <String, dynamic>{'n1': 'notatka'},
    );
    for (final CircleBackupService s in <CircleBackupService>[holder, fresh]) {
      await s.stop();
    }
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

/// Memory transports that deliver to each other (while in [nodes]),
/// through JSON as the network would.
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

List<Object?> _offersFrom(_Linked t) => <Object?>[
  for (final s in t.sentSignals)
    if (s.payload['type'] == CircleBackupMessages.offer) s.payload['m'],
];

List<Object?> _refusals(_Linked t) => <Object?>[
  for (final s in t.sentSignals)
    if (s.payload['type'] == CircleBackupMessages.no) s.payload['why'],
];

CircleBackupIdentity _idOf(LedgerIdentity i) => CircleBackupIdentity(
  account: i.account,
  selfKey: i.selfKey!,
  deviceKey: i.deviceKey,
  certificate: i.certificate,
);

/// The full copy: passwords, notes and chats.
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

/// What a freshly recovered phone has before the copy came back.
CircleBackupContent _empty() => const CircleBackupContent(
  sections: <String, Object?>{
    CircleBackupSections.profile: <String, dynamic>{'displayName': 'Ola'},
  },
);

Future<CircleBackupBuild> _build(LedgerIdentity me, {required int at}) =>
    buildCircleBackup(
      content: _full(),
      account: me.account,
      selfKey: me.selfKey!,
      deviceKey: me.deviceKey,
      certificate: me.certificate,
      at: at,
    );

Future<void> _keep(CircleBackupService holder, CircleBackupBuild b) async {
  await holder.holder.offer(b.manifest);
  for (final MapEntry<String, Uint8List> e in b.chunks.entries) {
    await holder.holder.putChunk(b.manifest.account, e.key, e.value);
  }
}
