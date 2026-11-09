import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_copy.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Devices that reach each other directly (a local link in tests).
final class _Link extends MemorySignalTransport {
  _Link(this.address, this.net);

  final String address;
  final Map<String, _Link> net;

  /// Drops what this device sends while true (the link goes down).
  bool down = false;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    if (down) {
      return;
    }
    final _Link? to = net[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (to != null) {
      scheduleMicrotask(
        () => to.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<_Link> _device(String address, Map<String, _Link> net) async {
  final _Link link = _Link(PeerShareCodec.normalizeAddress(address), net);
  net[link.address] = link;
  await link.start();
  return link;
}

Uint8List _bytes(int n, int seed) =>
    Uint8List.fromList(List<int>.generate(n, (int i) => (i * 7 + seed) % 253));

/// A copy of an account with a large file (several blocks), a small one
/// and a stored state.
AccountArchiveBuild _copy() {
  final AccountArchiveBuilder b = AccountArchiveBuilder(
    account: 'acc-1',
    scope: kAllAccountScopes,
  )..seed = Uint8List.fromList(List<int>.filled(32, 3));
  final String video = b.addBytes(_bytes(kAccountCopyBlockBytes * 3 + 99, 1));
  final String note = b.addBytes(_bytes(10, 2));
  b.chats['200::1'] = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'm1',
      's': 'me',
      't': '',
      'at': 1,
      'ty': 'video',
      'af': video,
    },
    <String, dynamic>{'id': 'm2', 's': 'me', 't': 'hej', 'at': 2},
  ];
  b.raw['films/state'] = note;
  b.sections['settings'] = <String, dynamic>{'look': 'calm'};
  return (archive: b.build(at: 9), blobs: b.blobs);
}

/// Sizes of the reads of the copy's files on the old device.
final List<int> asked = <int>[];

/// A file of a copy, whole (tests only).
Future<Uint8List> _all(AccountArchiveBlob blob) async {
  final BytesBuilder out = BytesBuilder(copy: false);
  await for (final Uint8List part in blob.chunks()) {
    out.add(part);
  }
  return out.takeBytes();
}

Future<void> _settle() async {
  for (int i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Map<String, _Link> net;
  late _Link old;
  late _Link fresh;
  late AccountArchiveBuild copy;

  setUp(() async {
    net = <String, _Link>{};
    old = await _device('200::a', net);
    fresh = await _device('200::b', net);
    asked.clear();
    final AccountArchiveBuild plain = _copy();
    // Every read the old device makes is recorded: one block at most.
    copy = (
      archive: plain.archive,
      blobs: <String, AccountArchiveBlob>{
        for (final MapEntry<String, AccountArchiveBlob> e
            in plain.blobs.entries)
          e.key: AccountArchiveBlob(e.value.size, (int start, int end) {
            asked.add(end - start);
            return e.value.range(start, end);
          }),
      },
    );
  });

  AccountCopySource source() => AccountCopySource(
    transport: old,
    address: old.address,
    prepare: () async =>
        AccountCopyContent(build: copy, siblings: <String>[old.address]),
  );

  test('the ticket survives its text form and nothing else parses', () async {
    final AccountCopySource s = source();
    addTearDown(s.dispose);
    final AccountCopyTicket ticket = await s.open();
    final String text = ticket.encode();
    expect(text, startsWith(kAccountCopyTicketPrefix));
    final AccountCopyTicket back = AccountCopyTicket.parse(text)!;
    expect(back.address, old.address);
    expect(back.key, ticket.key);
    expect(back.token, ticket.token);
    expect(AccountCopyTicket.parse('200::a'), isNull);
    expect(AccountCopyTicket.parse('zen-copy:bm9wZQ'), isNull);
  });

  test('the whole account goes to a new device over a local link, after '
      'the person allows it on the old one', () async {
    final AccountCopySource s = source();
    addTearDown(s.dispose);
    final AccountCopyTicket ticket = await s.open();
    final AccountImportStaging staging = AccountImportStaging(
      MemoryLedgerDisk(),
    );
    final AccountCopyTarget target = AccountCopyTarget(
      transport: fresh,
      ticket: AccountCopyTicket.parse(ticket.encode())!,
      staging: staging,
      deviceName: 'Telefon (Android)',
      blockTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(target.dispose);

    final String digits = (await target.hello())!;
    await _settle();
    // Asked on the old device, with the same digits; nothing sent yet.
    expect(s.state, AccountCopySendState.asked);
    expect(s.request!.digits, digits);
    expect(s.request!.name, 'Telefon (Android)');
    expect(
      fresh.sentSignals.where(
        (({String remoteAddress, Map<String, dynamic> payload}) x) =>
            x.payload['type'] == AccountCopyMessages.offer,
      ),
      isEmpty,
    );

    final Future<AccountCopyOffer?> offered = target.offer();
    await s.allow();
    final AccountCopyOffer offer = (await offered)!;
    expect(offer.account, 'acc-1');
    expect(offer.seed, copy.archive.seed);
    expect(offer.siblings, <String>[old.address]);

    final List<int> progress = <int>[];
    final AccountArchive got = await target.download(
      offer,
      progress: (int done, int total) => progress.add(done),
    );
    await _settle();
    // What the old device read (before this test reads the files whole
    // below to compare them).
    final List<int> reads = List<int>.of(asked);
    expect(got.account, 'acc-1');
    expect(got.seed, copy.archive.seed);
    expect(got.chats['200::1']!.length, 2);
    expect(got.raw, copy.archive.raw);
    for (final MapEntry<String, int> f in copy.archive.files.entries) {
      expect(
        await staging.read(f.key, f.value),
        await _all(copy.blobs[f.key]!),
      );
    }
    expect(progress.last, offer.totalBytes);
    // The old device read the files block by block, never whole.
    expect(reads, isNotEmpty);
    expect(reads, everyElement(lessThanOrEqualTo(kAccountCopyBlockBytes)));
    expect(s.state, AccountCopySendState.done);
    // Everything after the greeting's fresh value is sealed: no file
    // bytes in clear.
    for (final ({String remoteAddress, Map<String, dynamic> payload}) x
        in old.sentSignals) {
      if (x.payload['type'] == AccountCopyMessages.nonce) {
        expect(x.payload.keys, unorderedEquals(<String>['type', 'r']));
        continue;
      }
      expect(x.payload.keys, everyElement(isIn(<String>['type', 'c'])));
    }
    // The new device's key went out only after the old device answered its
    // commitment.
    final List<Object?> order = <Object?>[
      for (final ({String remoteAddress, Map<String, dynamic> payload}) x
          in fresh.sentSignals)
        x.payload['type'],
    ];
    expect(order.first, AccountCopyMessages.hello);
    expect(order[1], AccountCopyMessages.key);
    expect(fresh.sentSignals.first.payload.containsKey('e'), isFalse);
  });

  test('a greeting without the code\'s token is ignored', () async {
    final AccountCopySource s = source();
    addTearDown(s.dispose);
    final AccountCopyTicket ticket = await s.open();
    final AccountCopyTarget stranger = AccountCopyTarget(
      transport: fresh,
      ticket: AccountCopyTicket(
        address: ticket.address,
        key: ticket.key,
        token: Uint8List(16),
      ),
      staging: AccountImportStaging(MemoryLedgerDisk()),
      deviceName: 'Obcy',
      answerTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(stranger.dispose);
    await expectLater(stranger.hello(), throwsA(isA<TimeoutException>()));
    await _settle();
    expect(s.state, AccountCopySendState.waiting);
    expect(s.request, isNull);
  });

  test('a device that saw the code and greets first cannot pick its key '
      'after the fact: it is bound to its commitment, and the new device '
      'shows no digits to aim at', () async {
    final AccountCopySource s = source();
    addTearDown(s.dispose);
    final AccountCopyTicket ticket = await s.open();
    final _Link evil = await _device('200::e', net);
    final List<Map<String, dynamic>> heard = <Map<String, dynamic>>[];
    final StreamSubscription<SignalTransportFrame> listening = evil.frames
        .listen((SignalTransportFrame f) => heard.add(f.payload));
    addTearDown(listening.cancel);
    // It saw the code (the token too) and greets first, committed to one
    // key.
    final Uint8List committed = Uint8List.fromList(List<int>.filled(32, 7));
    final Uint8List commitment = await accountCopyCommitment(committed);
    await evil.send(
      remoteAddress: old.address,
      payload: <String, dynamic>{
        'type': AccountCopyMessages.hello,
        'v': kAccountCopyVersion,
        'c': base64Url.encode(commitment),
        'm': base64Url.encode(
          await accountCopyHelloTag(ticket.token, commitment),
        ),
        'n': 'Obcy',
      },
    );
    await _settle();
    expect(
      heard.map((Map<String, dynamic> p) => p['type']),
      contains(AccountCopyMessages.nonce),
    );
    // The real new device comes second: no answer, so no digits on its
    // screen for anyone to read and aim at.
    final AccountCopyTarget target = AccountCopyTarget(
      transport: fresh,
      ticket: ticket,
      staging: AccountImportStaging(MemoryLedgerDisk()),
      deviceName: 'Laptop',
      answerTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(target.dispose);
    await expectLater(target.hello(), throwsA(isA<TimeoutException>()));
    // Any other key than the committed one opens nothing on the old device.
    await evil.send(
      remoteAddress: old.address,
      payload: <String, dynamic>{
        'type': AccountCopyMessages.key,
        'e': base64Url.encode(List<int>.filled(32, 9)),
      },
    );
    await _settle();
    expect(s.request, isNull);
    expect(s.state, AccountCopySendState.waiting);
  });

  test('between this version and 1.16.2 the move ends with "update first" '
      'on the side that can say it, never half way', () async {
    // A code of 1.16.2 is read here (the same fields) ...
    final String code116 =
        '$kAccountCopyTicketPrefix${base64Url.encode(utf8.encode(jsonEncode(<String, dynamic>{'v': 1, 'app': '1.16.2', 'a': old.address, 'k': base64Url.encode(List<int>.filled(32, 1)), 't': base64Url.encode(List<int>.filled(16, 2))})))}';
    final AccountCopyTicket? ticket116 = AccountCopyTicket.parse(code116);
    expect(ticket116, isNotNull);
    expect(AccountCopyTicket.otherVersion(code116), isNull);
    // ... and 1.16.2 answers this version's greeting with "no, version",
    // as its code does for any greeting not of version 1.
    final StreamSubscription<SignalTransportFrame> old116 = old.frames.listen((
      SignalTransportFrame f,
    ) {
      if (f.payload['type'] == AccountCopyMessages.hello &&
          f.payload['v'] != 1) {
        unawaited(
          old.send(
            remoteAddress: f.from,
            payload: <String, dynamic>{
              'type': AccountCopyMessages.no,
              'why': 'version',
              'app': '1.16.2',
            },
          ),
        );
      }
    });
    addTearDown(old116.cancel);
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final AccountCopyTarget target = AccountCopyTarget(
      transport: fresh,
      ticket: ticket116!,
      staging: AccountImportStaging(disk),
      deviceName: 'Laptop',
      answerTimeout: const Duration(seconds: 2),
    );
    addTearDown(target.dispose);
    expect(await target.hello(), isNull);
    expect(await target.offer(), isNull);
    expect(target.versionMismatch, '1.16.2');
    expect(disk.files, isEmpty);
    await old116.cancel();

    // This version's code read by 1.16.2: it reads version 1 only, so it
    // finds another version in it (what its screen turns into "update").
    final AccountCopySource s = source();
    addTearDown(s.dispose);
    final AccountCopyTicket ticket = await s.open();
    final Map<String, dynamic> json =
        jsonDecode(
              utf8.decode(
                base64Url.decode(
                  ticket.encode().substring(kAccountCopyTicketPrefix.length),
                ),
              ),
            )
            as Map<String, dynamic>;
    expect(json['v'], isNot(1));
    expect(json['app'], isNotNull);

    // A 1.16.2 greeting (its key in the clear) is answered with "no,
    // version", never taken.
    await fresh.send(
      remoteAddress: old.address,
      payload: <String, dynamic>{
        'type': AccountCopyMessages.hello,
        'v': 1,
        'e': base64Url.encode(List<int>.filled(32, 4)),
        'm': base64Url.encode(List<int>.filled(16, 5)),
        'n': 'Stary',
      },
    );
    await _settle();
    final Map<String, dynamic> no = old.sentSignals.last.payload;
    expect(no['type'], AccountCopyMessages.no);
    expect(no['why'], 'version');
    expect(s.request, isNull);
    expect(s.state, AccountCopySendState.waiting);
  });

  test('a transfer cut short goes on where it stopped', () async {
    final AccountCopySource s = source();
    addTearDown(s.dispose);
    final AccountCopyTicket ticket = await s.open();
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final AccountCopyTarget first = AccountCopyTarget(
      transport: fresh,
      ticket: ticket,
      staging: AccountImportStaging(disk),
      deviceName: 'Laptop',
      blockTimeout: const Duration(milliseconds: 50),
      retries: 0,
    );
    await first.hello();
    await _settle();
    final Future<AccountCopyOffer?> offered = first.offer();
    await s.allow();
    final AccountCopyOffer offer = (await offered)!;
    // The old device goes away after a few blocks.
    int received = 0;
    final StreamSubscription<SignalTransportFrame> watch = fresh.frames.listen((
      SignalTransportFrame f,
    ) {
      if (f.payload['type'] == AccountCopyMessages.block && ++received >= 3) {
        old.down = true;
      }
    });
    addTearDown(watch.cancel);
    await expectLater(first.download(offer), throwsA(isA<TimeoutException>()));
    await first.dispose();
    final int kept = disk.files.keys
        .where((String k) => k.startsWith('account/import/b/'))
        .length;
    expect(kept, greaterThanOrEqualTo(2));

    // Back: a new code, the same staging; only the missing blocks travel.
    old.down = false;
    await watch.cancel();
    final AccountCopySource again = source();
    addTearDown(again.dispose);
    final AccountCopyTicket ticket2 = await again.open();
    final AccountCopyTarget second = AccountCopyTarget(
      transport: fresh,
      ticket: ticket2,
      staging: AccountImportStaging(disk),
      deviceName: 'Laptop',
      blockTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(second.dispose);
    await second.hello();
    await _settle();
    final Future<AccountCopyOffer?> offered2 = second.offer();
    await again.allow();
    final AccountCopyOffer offer2 = (await offered2)!;
    final int before = old.sentSignals.length;
    final AccountArchive got = await second.download(offer2);
    final int blocks = copy.archive.files.values.fold<int>(
      accountBlockCount(offer2.manifestSize),
      (int sum, int size) => sum + accountBlockCount(size),
    );
    final int served = old.sentSignals
        .sublist(before)
        .where(
          (({String remoteAddress, Map<String, dynamic> payload}) x) =>
              x.payload['type'] == AccountCopyMessages.block,
        )
        .length;
    expect(served, greaterThan(0));
    expect(served, lessThan(blocks), reason: 'staged blocks are skipped');
    expect(got.account, 'acc-1');
    for (final MapEntry<String, int> f in copy.archive.files.entries) {
      expect(
        await AccountImportStaging(disk).read(f.key, f.value),
        await _all(copy.blobs[f.key]!),
      );
    }
    expect(jsonEncode(got.chats), jsonEncode(copy.archive.chats));
  });
}
