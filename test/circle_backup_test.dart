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

/// The copy of an account's data at its recovery circle: built, sealed and
/// signed; only what changed travels; capped at its size, oldest chat text
/// out first; kept by holders who cannot read it, within their limits;
/// taken back after a recovery; anything changed on the way rejected.
void main() {
  late LedgerIdentity me;
  late MemoryLedgerDisk myDisk;

  setUp(() async {
    myDisk = MemoryLedgerDisk();
    me = await LedgerIdentity.loadOrCreate(myDisk);
  });

  final DateTime start = DateTime.utc(2025, 1, 10);

  Map<String, dynamic> message(String id, DateTime at, String text) =>
      <String, dynamic>{
        'id': id,
        's': 'ada',
        't': text,
        'at': at.millisecondsSinceEpoch,
        'd': 'incoming',
        'ty': 'text',
        'ds': 'none',
      };

  /// [months] months of [perMonth] messages in each of [conversations].
  CircleBackupContent content({
    int conversations = 2,
    int months = 3,
    int perMonth = 4,
    int textLength = 40,
  }) => CircleBackupContent(
    sections: <String, Object?>{
      CircleBackupSections.profile: <String, dynamic>{'displayName': 'Ola'},
      CircleBackupSections.contacts: <String, dynamic>{
        'v': 1,
        'friends': <Map<String, dynamic>>[
          <String, dynamic>{'a': '200::1', 'n': 'Ada'},
        ],
        'groups': <Map<String, dynamic>>[],
      },
      CircleBackupSections.levels: <String, String>{'200::1': 'close'},
      CircleBackupSections.wallet: <String, Object>{'balance': 1500},
    },
    chats: <String, List<Map<String, dynamic>>>{
      for (int c = 0; c < conversations; c++)
        'rozmowa-$c': <Map<String, dynamic>>[
          for (int m = 0; m < months; m++)
            for (int i = 0; i < perMonth; i++)
              message(
                'm$c-$m-$i',
                DateTime.utc(start.year, start.month + m, 10, i),
                'Spotkajmy się $c/$m/$i ${'x' * textLength}',
              ),
        ],
    },
  );

  Future<CircleBackupBuild> build(
    CircleBackupContent c, {
    int at = 1000,
    int maxBytes = kCircleBackupMaxBytes,
    LedgerIdentity? who,
  }) {
    final LedgerIdentity id = who ?? me;
    return buildCircleBackup(
      content: c,
      account: id.account,
      selfKey: id.selfKey!,
      deviceKey: id.deviceKey,
      certificate: id.certificate,
      at: at,
      maxBytes: maxBytes,
    );
  }

  group('the copy', () {
    test(
      'opens with the account key only, and holders cannot read it',
      () async {
        final CircleBackupBuild b = await build(content());
        expect(await b.manifest.verify(account: me.account), isTrue);
        final String sealed = latin1.decode(<int>[
          for (final Uint8List c in b.chunks.values) ...c,
        ]);
        expect(sealed.contains('Spotkajmy'), isFalse);
        expect(sealed.contains('Ola'), isFalse);
        expect(jsonEncode(b.manifest.json).contains('rozmowa'), isFalse);

        final CircleBackupOpened opened = await openCircleBackup(
          manifest: b.manifest,
          chunks: b.chunks,
          account: me.account,
          selfKey: me.selfKey!,
        );
        expect(opened.error, isNull);
        expect(
          opened.content!.sections[CircleBackupSections.profile],
          <String, dynamic>{'displayName': 'Ola'},
        );
        expect(opened.content!.chats['rozmowa-1'], hasLength(12));
        expect(opened.content!.messageCount, 24);

        // The same account recovered elsewhere (same account key) opens it.
        final MemoryLedgerDisk elsewhere = MemoryLedgerDisk();
        final LedgerIdentity recovered = await LedgerIdentity.adoptAccount(
          elsewhere,
          me.accountKey!.seed,
        );
        expect(recovered.selfKey, me.selfKey);
        // Another account does not.
        final LedgerIdentity other = await LedgerIdentity.loadOrCreate(
          MemoryLedgerDisk(),
        );
        expect(
          (await openCircleBackup(
            manifest: b.manifest,
            chunks: b.chunks,
            account: me.account,
            selfKey: other.selfKey!,
          )).error,
          CircleBackupError.sealing,
        );
      },
    );

    test('messages are kept as synced: edited and deleted ones keep their '
        'fields', () async {
      final Map<String, dynamic> edited = <String, dynamic>{
        ...message('e1', DateTime.utc(2025, 2, 1), 'Poprawiony tekst'),
        'ed': <String, dynamic>{'at': 123, 'n': 2},
      };
      final Map<String, dynamic> deleted = <String, dynamic>{
        ...message('d1', DateTime.utc(2025, 2, 2), ''),
        'del': true,
        'dat': 456,
      };
      final CircleBackupContent c = CircleBackupContent(
        chats: <String, List<Map<String, dynamic>>>{
          'group:g1': <Map<String, dynamic>>[edited, deleted],
        },
      );
      final CircleBackupBuild b = await build(c);
      final CircleBackupContent got = (await openCircleBackup(
        manifest: b.manifest,
        chunks: b.chunks,
        account: me.account,
        selfKey: me.selfKey!,
      )).content!;
      expect(got.chats['group:g1'], <Map<String, dynamic>>[edited, deleted]);
    });

    test('only what changed gives new chunks', () async {
      final CircleBackupBuild first = await build(content());
      final CircleBackupBuild again = await build(content(), at: 2000);
      Set<String> body(CircleBackupBuild b) =>
          b.chunks.keys.toSet()..removeAll(b.manifest.index);
      expect(body(again), body(first));

      final CircleBackupContent more = content();
      more.chats['rozmowa-0']!.add(
        message('nowa', DateTime.utc(2025, 3, 20), 'Nowa wiadomość'),
      );
      final CircleBackupBuild changed = await build(more, at: 3000);
      final Set<String> fresh = body(changed).difference(body(first));
      // Only the newest month of that one conversation.
      expect(fresh, hasLength(1));
    });

    test(
      'over the cap, the oldest chat text goes first and the rest stays',
      () async {
        final CircleBackupContent big = content(
          conversations: 3,
          months: 12,
          perMonth: 20,
          textLength: 400,
        );
        const int cap = 160 * 1024;
        final CircleBackupBuild b = await build(big, maxBytes: cap);
        expect(b.manifest.totalBytes, lessThanOrEqualTo(cap));
        expect(b.droppedMessages, greaterThan(0));
        final CircleBackupContent got = (await openCircleBackup(
          manifest: b.manifest,
          chunks: b.chunks,
          account: me.account,
          selfKey: me.selfKey!,
        )).content!;
        expect(got.sections.keys, containsAll(big.sections.keys));
        expect(got.messageCount, big.messageCount - b.droppedMessages);
        int newest(CircleBackupContent c) => c.chats.values
            .expand((List<Map<String, dynamic>> l) => l)
            .map((Map<String, dynamic> m) => m['at'] as int)
            .reduce((int a, int b) => a > b ? a : b);
        int oldest(CircleBackupContent c) => c.chats.values
            .expand((List<Map<String, dynamic>> l) => l)
            .map((Map<String, dynamic> m) => m['at'] as int)
            .reduce((int a, int b) => a < b ? a : b);
        expect(newest(got), newest(big));
        expect(oldest(got), greaterThan(oldest(big)));
      },
    );

    test('anything changed on the way is rejected', () async {
      final CircleBackupBuild b = await build(content());
      // A chunk changed.
      final String id = b.chunks.keys.first;
      final Map<String, Uint8List> tampered = Map<String, Uint8List>.of(
        b.chunks,
      )..[id] = (Uint8List.fromList(b.chunks[id]!)..[20] ^= 1);
      expect(
        (await openCircleBackup(
          manifest: b.manifest,
          chunks: tampered,
          account: me.account,
          selfKey: me.selfKey!,
        )).error,
        CircleBackupError.chunks,
      );
      // The manifest changed (a newer time).
      final Map<String, dynamic> json =
          jsonDecode(jsonEncode(b.manifest.json)) as Map<String, dynamic>;
      json['at'] = 999999;
      final CircleBackupManifest forged = CircleBackupManifest.parse(json)!;
      expect(await forged.verify(), isFalse);
      // Signed by another account's device, claimed for this one.
      final LedgerIdentity other = await LedgerIdentity.loadOrCreate(
        MemoryLedgerDisk(),
      );
      final CircleBackupBuild theirs = await build(content(), who: other);
      expect(await theirs.manifest.verify(account: me.account), isFalse);
      expect(
        (await openCircleBackup(
          manifest: theirs.manifest,
          chunks: theirs.chunks,
          account: me.account,
          selfKey: me.selfKey!,
        )).error,
        CircleBackupError.signature,
      );
    });
  });

  group('a holder', () {
    test('keeps only copies of its circles, within its limits, and only '
        'what it lacks travels', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final Set<String> circles = <String>{};
      final CircleBackupHolder holder = CircleBackupHolder(
        disk: disk,
        isInCircle: circles.contains,
        perAccountBytes: 200 * 1024,
      );
      final CircleBackupBuild b = await build(content());
      expect(
        await holder.offer(b.manifest),
        CircleBackupOfferResult.notInCircle,
      );
      circles.add(me.account);
      expect(await holder.offer(b.manifest), CircleBackupOfferResult.accepted);
      expect(await holder.missing(me.account), hasLength(b.chunks.length));
      // A chunk that is not what its id says is not kept.
      final String first = b.chunks.keys.first;
      expect(
        await holder.putChunk(me.account, first, Uint8List.fromList(<int>[1])),
        isFalse,
      );
      bool complete = false;
      for (final MapEntry<String, Uint8List> e in b.chunks.entries) {
        complete = await holder.putChunk(me.account, e.key, e.value);
      }
      expect(complete, isTrue);
      expect(holder.kept[me.account], b.manifest.totalBytes);
      expect(await holder.chunk(me.account, first), b.chunks[first]);

      // A newer copy: only the changed chunks are asked for.
      final CircleBackupContent more = content();
      more.chats['rozmowa-1']!.add(
        message('nowa', DateTime.utc(2025, 3, 21), 'Nowa'),
      );
      final CircleBackupBuild next = await build(more, at: 5000);
      expect(
        await holder.offer(next.manifest),
        CircleBackupOfferResult.accepted,
      );
      expect(await holder.missing(me.account), hasLength(2));
      // An older one is refused.
      expect(await holder.offer(b.manifest), CircleBackupOfferResult.stale);

      // Too big for one copy.
      final CircleBackupBuild huge = await build(
        content(months: 12, perMonth: 30, textLength: 800),
        at: 6000,
      );
      expect(huge.manifest.totalBytes, greaterThan(200 * 1024));
      expect(await holder.offer(huge.manifest), CircleBackupOfferResult.tooBig);

      // Out of the circle: the copy goes.
      circles.clear();
      expect(await holder.prune(), 1);
      expect(holder.kept, isEmpty);
      expect(await holder.chunk(me.account, first), isNull);
      expect(
        disk.files.keys.where((String k) => k.startsWith('circle-backup/k/')),
        isEmpty,
      );
    });
  });

  test('after a recovery the copy comes back from the circle', () async {
    _Linked.nodes.clear();
    final _Linked tOwner = _Linked('200::a');
    final _Linked tHolder = _Linked('200::b');
    final _Linked tNew = _Linked('200::c');
    for (final _Linked t in <_Linked>[tOwner, tHolder, tNew]) {
      await t.start();
    }
    CircleBackupIdentity idOf(LedgerIdentity i) => CircleBackupIdentity(
      account: i.account,
      selfKey: i.selfKey!,
      deviceKey: i.deviceKey,
      certificate: i.certificate,
    );
    // One message edited and one deleted for everyone, as synced.
    final CircleBackupContent ours = content();
    final Map<String, dynamic> edited = <String, dynamic>{
      ...message('e1', DateTime.utc(2025, 3, 2), 'Poprawione'),
      'ed': <String, dynamic>{'at': 1, 'n': 1},
    };
    final Map<String, dynamic> deleted = <String, dynamic>{
      ...message('d1', DateTime.utc(2025, 3, 3), ''),
      'del': true,
    };
    ours.chats['rozmowa-0']!.addAll(<Map<String, dynamic>>[edited, deleted]);
    final _MemoryData mine = _MemoryData(ours);
    final CircleBackupService owner = CircleBackupService(
      transport: tOwner,
      disk: myDisk,
      data: mine,
      identity: () => idOf(me),
      holders: () => <String>[tHolder.address],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
    );
    final CircleBackupService holder = CircleBackupService(
      transport: tHolder,
      disk: MemoryLedgerDisk(),
      data: _MemoryData(const CircleBackupContent()),
      identity: () => null,
      holders: () => const <String>[],
      isInCircle: (String a) => a == me.account,
      restoreCandidates: () => const <String>[],
    );
    await holder.start();
    // Its first tick makes the copy and offers it.
    await owner.start();
    await _settle(<CircleBackupService>[owner, holder]);
    expect(holder.holder.kept.keys, <String>[me.account]);
    expect(owner.status.value.lastAt, isNotNull);
    expect(owner.status.value.holders, 1);
    expect(owner.status.value.bytes, greaterThan(0));

    // The phone is lost; the account comes back on a new one.
    final MemoryLedgerDisk newDisk = MemoryLedgerDisk();
    final LedgerIdentity recovered = await LedgerIdentity.adoptAccount(
      newDisk,
      me.accountKey!.seed,
    );
    await CircleBackupService.markRestore(
      newDisk,
      helpers: <String>[tHolder.address],
    );
    final _MemoryData restored = _MemoryData(const CircleBackupContent());
    final CircleBackupService fresh = CircleBackupService(
      transport: tNew,
      disk: newDisk,
      data: restored,
      identity: () => idOf(recovered),
      holders: () => const <String>[],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
    );
    expect(fresh.restore.value.phase, CircleBackupRestorePhase.idle);
    await fresh.start();
    await _settle(<CircleBackupService>[fresh, holder]);
    expect(fresh.restore.value.phase, CircleBackupRestorePhase.done);
    expect(restored.restoredContent!.messageCount, 26);
    expect(
      restored.restoredContent!.chats['rozmowa-0'],
      containsAll(<Map<String, dynamic>>[edited, deleted]),
    );
    expect(
      restored.restoredContent!.sections[CircleBackupSections.wallet],
      <String, dynamic>{'balance': 1500},
    );
    expect(fresh.restoring, isFalse);

    // A device of another account asking for it gets nothing.
    final LedgerIdentity stranger = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final _Linked tStranger = _Linked('200::d');
    await tStranger.start();
    final MemoryLedgerDisk strangerDisk = MemoryLedgerDisk();
    await CircleBackupService.markRestore(
      strangerDisk,
      helpers: <String>[tHolder.address],
    );
    final _MemoryData nothing = _MemoryData(const CircleBackupContent());
    final CircleBackupService thief = CircleBackupService(
      transport: tStranger,
      disk: strangerDisk,
      data: nothing,
      identity: () => CircleBackupIdentity(
        // Claims the account, signs with its own device.
        account: me.account,
        selfKey: stranger.selfKey!,
        deviceKey: stranger.deviceKey,
        certificate: stranger.certificate,
      ),
      holders: () => const <String>[],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
    );
    await thief.start();
    await _settle(<CircleBackupService>[thief, holder]);
    expect(nothing.restoredContent, isNull);
    expect(
      tHolder.sentSignals.where(
        (({String remoteAddress, Map<String, dynamic> payload}) s) =>
            s.remoteAddress == tStranger.address,
      ),
      isEmpty,
    );

    for (final CircleBackupService s in <CircleBackupService>[
      owner,
      holder,
      fresh,
      thief,
    ]) {
      await s.stop();
    }
  });
}

Future<void> _settle(List<CircleBackupService> services) async {
  for (int i = 0; i < 200; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    for (final CircleBackupService s in services) {
      await s.idle;
    }
  }
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

/// Memory transports that deliver to each other, through JSON as the
/// network would.
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
    if (target != null) {
      final Map<String, dynamic> wire =
          jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: wire),
      );
    }
  }
}
